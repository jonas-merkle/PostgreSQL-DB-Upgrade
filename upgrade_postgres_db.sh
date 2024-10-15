#!/bin/bash

# This script must be run as root or with sudo to ensure proper permissions.

# Function to check if a command is successful
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
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

# Load the environment variables
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
DUMP_CONTAINER="pg_dump_ubuntu"
DUMP_VOLUME="pg_dump_volume"
DB_DUMP_FILE="/dump/db_dump.sql"

# Step 1: Copy the content of the data directory to a temporary location (without changing ownership)
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

# Step 3: Create a new Docker volume for the dump
log "Creating dump volume..."
docker volume create $DUMP_VOLUME
check_success "Failed to create dump volume."

# Step 4: Start another container based on Ubuntu, install pg_dumpall for the new version, and create a dump
log "Creating database dump container..."
docker run -d --name $DUMP_CONTAINER --network $NETWORK_NAME \
    -v $DUMP_VOLUME:/dump \
    ubuntu:latest tail -f /dev/null
check_success "Failed to start dump container."

log "Installing PostgreSQL client $NEW_PG_VERSION in the dump container..."
docker exec $DUMP_CONTAINER apt-get update -y
check_success "Failed to update the package list in the dump container."

docker exec $DUMP_CONTAINER apt-get install -y postgresql-client-$NEW_PG_VERSION
check_success "Failed to install PostgreSQL client $NEW_PG_VERSION."

log "Creating a database dump using pg_dumpall..."
docker exec $DUMP_CONTAINER pg_dumpall -h $OLD_PG_CONTAINER -U $POSTGRES_USER -f $DB_DUMP_FILE
check_success "Failed to create database dump."

# Step 5: Stop both containers but keep the network and dump volume
log "Stopping PostgreSQL $CURR_PG_VERSION container..."
docker stop $OLD_PG_CONTAINER
docker rm $OLD_PG_CONTAINER
check_success "Failed to stop and remove PostgreSQL $CURR_PG_VERSION container."

log "Stopping dump container..."
docker stop $DUMP_CONTAINER
docker rm $DUMP_CONTAINER
check_success "Failed to stop and remove dump container."

# Step 6: Remove the content of the data directory
log "Removing old data directory contents..."
rm -rf "$DATA_DIR"/*
check_success "Failed to remove old data directory contents."

# Step 7: Start a new PostgreSQL container with the new version and import data from the dump
log "Starting PostgreSQL $NEW_PG_VERSION container..."
docker run -d --name $NEW_PG_CONTAINER --network $NETWORK_NAME \
    -v "$DATA_DIR:/var/lib/postgresql/data" \
    -v $DUMP_VOLUME:/dump \
    -e POSTGRES_USER=$POSTGRES_USER \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    -e POSTGRES_DB=$POSTGRES_DB \
    postgres:$NEW_PG_VERSION
check_success "Failed to start PostgreSQL $NEW_PG_VERSION container."

log "Waiting for PostgreSQL $NEW_PG_VERSION container to start..."
sleep 10

log "Restoring the dump into the new PostgreSQL instance..."
docker exec -i $NEW_PG_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -f $DB_DUMP_FILE
check_success "Failed to restore the dump into the new PostgreSQL instance."

# Step 8: Reindex the database
log "Reindexing the database..."
docker exec -i $NEW_PG_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB -c "REINDEX DATABASE $POSTGRES_DB;"
check_success "Failed to reindex the database."

# Step 9: Stop all running containers and clean up network and volumes
log "Stopping PostgreSQL $NEW_PG_VERSION container..."
docker stop $NEW_PG_CONTAINER
docker rm $NEW_PG_CONTAINER
check_success "Failed to stop and remove PostgreSQL $NEW_PG_VERSION container."

log "Removing Docker network and dump volume..."
docker network rm $NETWORK_NAME
docker volume rm $DUMP_VOLUME
check_success "Failed to remove Docker network and dump volume."

# Step 10: Handle errors - restore the data directory if necessary
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

# Cleanup temporary directory
log "Cleaning up temporary directory..."
rm -rf "$TEMP_DIR"
check_success "Failed to clean up temporary directory."

log "Script completed successfully."
