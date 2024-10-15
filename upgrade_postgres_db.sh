#!/bin/bash

# This script must be run as root or with sudo to ensure proper permissions.

# Function to check if a command is successful
check_success() {
    if [ $? -ne 0 ]; then
        log "Error: $1"
        cleanup
        exit 1
    fi
}

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

cleanup() {
    log "Cleaning up: Stopping and removing any active containers, volumes, network, and temporary files."

    docker stop $OLD_PG_CONTAINER $NEW_PG_CONTAINER $DUMP_CONTAINER 2>/dev/null || true
    docker rm $OLD_PG_CONTAINER  $NEW_PG_CONTAINER $DUMP_CONTAINER 2>/dev/null || true
    docker volume rm $DUMP_VOLUME 2>/dev/null || true
    docker network rm $NETWORK_NAME 2>/dev/null || true

    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR" && log "Temporary directory cleaned up."

    log "Cleanup completed."
}

# Trap errors and script exit for cleanup
trap cleanup EXIT ERR SIGINT SIGTERM

wait_for_postgres_ready() {
    local container_name=$1
    local retries=10
    local wait_time=3
    local attempt=0

    log "Waiting for PostgreSQL container '$container_name' to be ready..."

    until docker exec -i $container_name pg_isready -U $POSTGRES_USER > /dev/null 2>&1; do
        attempt=$((attempt+1))
        if [ $attempt -ge $retries ]; then
            log "PostgreSQL container '$container_name' is not ready after $retries attempts."
            exit 1
        fi
        log "PostgreSQL container '$container_name' is not ready yet. Retrying in $wait_time seconds... (Attempt $attempt)"
        sleep $wait_time
    done

    log "PostgreSQL container '$container_name' is ready."
}

# Get script parameters
DATA_DIR=$1
CURR_PG_VERSION=$2
NEW_PG_VERSION=$3
TEMP_DIR=$(mktemp -d)

log "Script started."

# Ensure the script is run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log "Please run this script as root or use sudo."
    exit 1
fi

# Step 0: Check if necessary parameters are provided
if [ -z "$DATA_DIR" ] || [ -z "$CURR_PG_VERSION" ] || [ -z "$NEW_PG_VERSION" ]; then
    log "Usage: $0 <path_to_data_directory> <current_postgres_version> <new_postgres_version>"
    exit 1
fi

# Load the .env file and check if the required environment variables are set
if [ ! -f ".env" ]; then
    log "Error: .env file not found. Please provide the file with POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB variables."
    exit 1
fi

log "Loading .env file..."
set -o allexport
source .env
set +o allexport
check_success "Failed to load .env file."

# Check if the necessary variables are loaded
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_DB" ]; then
    log "Error: Required variables POSTGRES_USER, POSTGRES_PASSWORD, or POSTGRES_DB are missing in the .env file."
    exit 1
fi

# Streamlined container, volume, and network names
NETWORK_NAME="pg_upgrade_net"
OLD_PG_CONTAINER="pg_old_$CURR_PG_VERSION"
NEW_PG_CONTAINER="pg_new_$NEW_PG_VERSION"
DUMP_CONTAINER="pg_dump_container"
DUMP_VOLUME="pg_dump_volume"
DB_DUMP_FILE="/dump/db_dump.sql"

# Step 1: Copy the content of the data directory to a temporary location
log "Copying data directory to a temporary location..."
cp -a "$DATA_DIR"/* "$TEMP_DIR/"
check_success "Failed to copy the data directory to a temporary location."

# Step 2: Start a new Postgres server with the current version in Docker
log "Starting PostgreSQL $CURR_PG_VERSION container..."
docker network create $NETWORK_NAME
check_success "Failed to create Docker network."

docker run -d --name $OLD_PG_CONTAINER --network $NETWORK_NAME \
    -v "$DATA_DIR:/var/lib/postgresql/data" \
    -e POSTGRES_USER=$POSTGRES_USER \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    -e POSTGRES_DB=$POSTGRES_DB \
    postgres:$CURR_PG_VERSION
check_success "Failed to start PostgreSQL $CURR_PG_VERSION container."

# Step 3: Wait for the PostgreSQL server to be ready
wait_for_postgres_ready $OLD_PG_CONTAINER

# Step 4: Create a new Docker volume for the dump
log "Creating dump volume..."
docker volume create $DUMP_VOLUME
check_success "Failed to create dump volume."

# Step 5: Start a PostgreSQL container for dumping
log "Starting PostgreSQL container for dump..."
docker run -d --name $DUMP_CONTAINER --network $NETWORK_NAME \
    -v $DUMP_VOLUME:/dump \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    postgres:$NEW_PG_VERSION tail -f /dev/null
check_success "Failed to start PostgreSQL dump container."

log "Creating a database dump using pg_dumpall..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD -i $DUMP_CONTAINER pg_dumpall -h $OLD_PG_CONTAINER -U $POSTGRES_USER -f $DB_DUMP_FILE
check_success "Failed to create database dump."

# Step 6: Stop and remove the old Postgres container
log "Stopping and removing PostgreSQL $CURR_PG_VERSION container..."
docker stop $OLD_PG_CONTAINER
docker rm $OLD_PG_CONTAINER
check_success "Failed to stop and remove PostgreSQL $CURR_PG_VERSION container."

# Step 7: Remove the content of the data directory
log "Removing old data directory contents..."
rm -rf "$DATA_DIR"/*
check_success "Failed to remove old data directory contents."

# Step 8: Start a new PostgreSQL container with the new version and import data from the dump
log "Starting PostgreSQL $NEW_PG_VERSION container..."
docker run -d --name $NEW_PG_CONTAINER --network $NETWORK_NAME \
    -v "$DATA_DIR:/var/lib/postgresql/data" \
    -v $DUMP_VOLUME:/dump \
    -e POSTGRES_USER=$POSTGRES_USER \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    postgres:$NEW_PG_VERSION
check_success "Failed to start PostgreSQL $NEW_PG_VERSION container."

wait_for_postgres_ready $NEW_PG_CONTAINER

log "Restoring the dump into the new PostgreSQL instance..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD -i $NEW_PG_CONTAINER psql -U $POSTGRES_USER -f $DB_DUMP_FILE
check_success "Failed to restore the dump into the new PostgreSQL instance."

# Step 10: Reindex the database
log "Reindexing the database..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD -i $NEW_PG_CONTAINER psql -U $POSTGRES_USER -c "REINDEX SYSTEM;"
check_success "Failed to reindex the database."

log "Checking for errors during the process..."
if [ $? -ne 0 ]; then
    log "An error occurred during the upgrade process. Restoring the data directory..."
    rm -rf "$DATA_DIR"/*
    cp -a "$TEMP_DIR"/* "$DATA_DIR/"
    check_success "Failed to restore the data directory."
    log "Restoration complete."
else
    log "Upgrade successful."
fi

log "Script completed successfully."