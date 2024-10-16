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

# PostgreSQL Initialization and Data Setup Script
# This script initializes a PostgreSQL database using Docker, creates tables, inserts dummy data, and cleans up.

# Function to log messages with timestamps
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Function to check if a command is successful
check_success() {
    if [ $? -ne 0 ]; then
        log "Error: $1"
        cleanup
        exit 1
    fi
}

# Cleanup function to stop and remove the container
cleanup() {
    log "Cleaning up resources..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    log "Cleanup completed."
}

# Trap errors and script exit to perform cleanup
trap 'cleanup' EXIT ERR SIGINT SIGTERM

# Check for the required arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <postgres_data_directory> <postgres_version>"
    exit 1
fi

POSTGRES_DATA_DIR=$1
POSTGRES_VERSION=$2

# Load environment variables from the .env file
if [ ! -f .env ]; then
    log ".env file not found!"
    exit 1
fi

source .env

# Ensure necessary environment variables are set
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_DB" ]; then
    log "POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB must be set in the .env file!"
    exit 1
fi

# Set container name
CONTAINER_NAME="postgres_container_$(date +%s)"

# Create or clean the data directory
log "Setting up the data directory..."
mkdir -p "$POSTGRES_DATA_DIR"
rm -rf "$POSTGRES_DATA_DIR"/*
check_success "Failed to set up the data directory."

# Start the PostgreSQL server in a Docker container
log "Starting PostgreSQL $POSTGRES_VERSION container..."
docker run --name "$CONTAINER_NAME" -e POSTGRES_USER="$POSTGRES_USER" -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -e POSTGRES_DB="$POSTGRES_DB" -v "$POSTGRES_DATA_DIR":/var/lib/postgresql/data \
    -d postgres:$POSTGRES_VERSION
check_success "Failed to start the Docker container."

# Wait for PostgreSQL to start
log "Waiting for PostgreSQL to start..."
for i in {1..10}; do
    if docker exec -i "$CONTAINER_NAME" pg_isready -U "$POSTGRES_USER" > /dev/null 2>&1; then
        log "PostgreSQL is ready."
        break
    fi
    sleep 3
    if [ $i -eq 10 ]; then
        log "Error: PostgreSQL did not become ready in time."
        exit 1
    fi
done

# Create tables and insert dummy data
log "Creating tables and inserting dummy data..."
docker exec -i "$CONTAINER_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(100)
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES users(id),
    product_name VARCHAR(100),
    quantity INT
);

INSERT INTO users (name, email) VALUES
('John Doe', 'john.doe@example.com'),
('Jane Smith', 'jane.smith@example.com');

INSERT INTO orders (user_id, product_name, quantity) VALUES
(1, 'Laptop', 1),
(2, 'Smartphone', 2);
EOF
check_success "Failed to create tables or insert data."

# Stop and optionally remove the container
cleanup

log "Postgres server started, dummy data created, and container stopped."