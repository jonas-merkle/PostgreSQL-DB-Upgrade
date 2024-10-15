#!/bin/bash

# Function to check if a command is successful
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Check for the required arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <postgres_data_directory> <postgres_version>"
    exit 1
fi

POSTGRES_DATA_DIR=$1
POSTGRES_VERSION=$2

# Load environment variables from the .env file
if [ ! -f .env ]; then
    echo ".env file not found!"
    exit 1
fi

source .env

# Ensure necessary environment variables are set
if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_DB" ]; then
    echo "POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB must be set in the .env file!"
    exit 1
fi

# Check if the data directory exists, and if not, create it
if [ ! -d "$POSTGRES_DATA_DIR" ]; then
    echo "Data directory does not exist. Creating it now..."
    mkdir -p "$POSTGRES_DATA_DIR"
    check_success "Failed to create the data directory."
fi

# Remove all contents of the data directory if it's not empty
if [ "$(ls -A $POSTGRES_DATA_DIR)" ]; then
    echo "Data directory is not empty. Deleting its contents..."
    rm -rf "$POSTGRES_DATA_DIR"/*
    check_success "Failed to clean the data directory."
else
    echo "Data directory is already empty."
fi

# Start the postgres server in a Docker container
CONTAINER_NAME="postgres_container_$(date +%s)"
docker run --name "$CONTAINER_NAME" -e POSTGRES_USER="$POSTGRES_USER" -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -e POSTGRES_DB="$POSTGRES_DB" -v "$POSTGRES_DATA_DIR":/var/lib/postgresql/data -d postgres:$POSTGRES_VERSION
check_success "Failed to start the Docker container."

echo "Waiting for Postgres to start..."
sleep 10  # Wait for the postgres server to initialize

# Create tables and dummy data
echo "Creating tables and inserting dummy data..."
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

# Stop the container after creating data
echo "Stopping the Docker container..."
docker stop "$CONTAINER_NAME"
check_success "Failed to stop the Docker container."

# Optionally remove the container (comment this line if you want to keep it)
docker rm "$CONTAINER_NAME"
check_success "Failed to remove the Docker container."

echo "Postgres server started, dummy data created, and container stopped."
