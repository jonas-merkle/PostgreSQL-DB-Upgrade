#!/bin/bash

# PostgreSQL DB Upgrade
# Copyright (C) 2024 [Jonas Merkle [JJM]](mailto:jonas@jjm.one?subject=%5BGitHub%5D%3A%20PostgreSQL%20DB%20Upgrade)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

# PostgreSQL Upgrade Script: Migrates data from one version to another using Docker.
# This script must be run as root or with sudo to ensure proper permissions.

# Function to log messages with timestamps
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if the last command was successful
check_success() {
    if [ $? -ne 0 ]; then
        log "Error: $1"
        restore_data_directory
        cleanup
        exit 1
    fi
}

# Cleanup function to stop and remove any active containers, volumes, networks, and temporary files
cleanup() {
    log "Cleaning up resources..."
    docker stop $OLD_PG_CONTAINER $NEW_PG_CONTAINER $DUMP_CONTAINER 2>/dev/null || true
    docker rm $OLD_PG_CONTAINER $NEW_PG_CONTAINER $DUMP_CONTAINER 2>/dev/null || true
    docker volume rm $DUMP_VOLUME 2>/dev/null || true
    docker network rm $NETWORK_NAME 2>/dev/null || true

    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log "Temporary directory cleaned up."
    fi
    log "Cleanup completed."
    exit 0
}

# Restore the data directory from the temporary backup
restore_data_directory() {
    if [ -d "$TEMP_DIR" ]; then
        log "Restoring data directory from backup..."
        rm -rf "$DATA_DIR"/*
        cp -a "$TEMP_DIR"/* "$DATA_DIR/"
        check_success "Failed to restore the data directory from the backup."
        log "Data directory restored successfully."
    else
        log "Temporary directory not found. Skipping data restoration."
    fi
}

# Trap errors and script exit to perform cleanup and data restoration
trap 'restore_data_directory; cleanup' EXIT ERR SIGINT SIGTERM

# Wait until PostgreSQL container is ready
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
            restore_data_directory
            exit 1
        fi
        sleep $wait_time
    done
    log "PostgreSQL container '$container_name' is ready."
}

# Get script parameters
DATA_DIR=$1
CURR_PG_VERSION=$2
NEW_PG_VERSION=$3
TEMP_DIR=$(mktemp -d)

log "Starting PostgreSQL upgrade script."

# Ensure the script is run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log "Please run this script as root or use sudo."
    exit 1
fi

# Validate required parameters
if [ -z "$DATA_DIR" ] || [ -z "$CURR_PG_VERSION" ] || [ -z "$NEW_PG_VERSION" ]; then
    log "Usage: $0 <path_to_data_directory> <current_postgres_version> <new_postgres_version>"
    exit 1
fi

# Load environment variables from .env file
if [ ! -f ".env" ]; then
    log "Error: .env file not found. Please provide the file with POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB variables."
    exit 1
fi

log "Loading .env file..."
set -o allexport
source .env
set +o allexport
check_success "Failed to load .env file."

# Validate environment variables
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_DB" ]; then
    log "Error: Required variables POSTGRES_USER, POSTGRES_PASSWORD, or POSTGRES_DB are missing in the .env file."
    exit 1
fi

# Set container, volume, and network names
NETWORK_NAME="pg_upgrade_net"
OLD_PG_CONTAINER="pg_old_$CURR_PG_VERSION"
NEW_PG_CONTAINER="pg_new_$NEW_PG_VERSION"
DUMP_CONTAINER="pg_dump_container"
DUMP_VOLUME="pg_dump_volume"
DB_DUMP_FILE="/dump/db_dump.sql"

# Step 1: Backup data directory
log "Backing up data directory to a temporary location..."
cp -a "$DATA_DIR"/* "$TEMP_DIR/"
check_success "Failed to backup the data directory."

# Step 2: Start old PostgreSQL container
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

# Step 3: Wait for PostgreSQL to be ready
wait_for_postgres_ready $OLD_PG_CONTAINER

# Step 4: Create Docker volume for dump
log "Creating dump volume..."
docker volume create $DUMP_VOLUME
check_success "Failed to create dump volume."

# Step 5: Start container for dump
log "Starting container for database dump..."
docker run -d --name $DUMP_CONTAINER --network $NETWORK_NAME \
    -v $DUMP_VOLUME:/dump \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    postgres:$NEW_PG_VERSION tail -f /dev/null
check_success "Failed to start dump container."

# Step 6: Create database dump
log "Creating a database dump..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD -i $DUMP_CONTAINER pg_dumpall -h $OLD_PG_CONTAINER -U $POSTGRES_USER -f $DB_DUMP_FILE
check_success "Failed to create database dump."

# Step 7: Stop and remove old PostgreSQL container
log "Stopping and removing old PostgreSQL container..."
docker stop $OLD_PG_CONTAINER && docker rm $OLD_PG_CONTAINER
check_success "Failed to stop and remove old PostgreSQL container."

# Step 8: Clear old data directory
log "Clearing old data directory contents..."
rm -rf "$DATA_DIR"/*
check_success "Failed to clear old data directory contents."

# Step 9: Start new PostgreSQL container
log "Starting PostgreSQL $NEW_PG_VERSION container..."
docker run -d --name $NEW_PG_CONTAINER --network $NETWORK_NAME \
    -v "$DATA_DIR:/var/lib/postgresql/data" \
    -v $DUMP_VOLUME:/dump \
    -e POSTGRES_USER=$POSTGRES_USER \
    -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD \
    postgres:$NEW_PG_VERSION
check_success "Failed to start PostgreSQL $NEW_PG_VERSION container."

# Step 10: Wait for new PostgreSQL to be ready
wait_for_postgres_ready $NEW_PG_CONTAINER

# Step 11: Restore database dump
log "Restoring database dump into the new PostgreSQL instance..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD -i $NEW_PG_CONTAINER psql -U $POSTGRES_USER -f $DB_DUMP_FILE
check_success "Failed to restore the database dump."

# Step 12: Reindex the database
log "Reindexing the database..."
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD -i $NEW_PG_CONTAINER psql -U $POSTGRES_USER -c "REINDEX SYSTEM;"
check_success "Failed to reindex the database."

# Final log message
log "PostgreSQL upgrade completed successfully."
cleanup
exit 0