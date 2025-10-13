#!/usr/bin/env bash

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


# ---------------------------------------------------------------------------
# PostgreSQL Docker Upgrade Script
#
# Safely upgrades a PostgreSQL database from version N to N+1 using Docker.
# The process:
#   1. Validate environment and arguments.
#   2. Back up current data directory.
#   3. Spin up old version in Docker to dump all databases.
#   4. Stop old version, start new version, and restore data.
#   5. Clean up containers, network, and temporary files.
#
# Key Safety Features:
#   - Absolute paths to avoid "No such file or directory" from relative paths.
#   - Non-recursive error handling (no infinite loops on failure).
#   - Rollback: restores data only once if something breaks.
#   - Robust copy using rsync (handles empty dirs gracefully).
# ---------------------------------------------------------------------------

set -Eeuo pipefail  # Exit on errors, unset vars, or failed pipes

# --- Logging function --------------------------------------------------------
log() {
  printf '%s - %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

# --- Arguments ---------------------------------------------------------------
DATA_DIR="${1:-}"
CURR_PG_VERSION="${2:-}"
NEW_PG_VERSION="${3:-}"

# Resolve DATA_DIR to absolute path (avoids relative path errors)
if [[ -n "$DATA_DIR" && "${DATA_DIR:0:1}" != "/" ]]; then
  DATA_DIR="$(readlink -f "$DATA_DIR")"
fi

# --- Global working vars -----------------------------------------------------
TEMP_DIR="$(mktemp -d)"  # Temporary dir for backup
BACKUP_TAKEN=0           # Flag to indicate backup success
RESTORE_ATTEMPTED=0      # Prevent multiple restores

# Unique names for containers and volumes to avoid collisions
NETWORK_NAME="pg_upgrade_net_$RANDOM"
OLD_PG_CONTAINER="pg_old_${CURR_PG_VERSION}_$RANDOM"
NEW_PG_CONTAINER="pg_new_${NEW_PG_VERSION}_$RANDOM"
DUMP_CONTAINER="pg_dump_container_$RANDOM"
DUMP_VOLUME="pg_dump_volume_$RANDOM"

# Paths inside dump container
DB_DUMP_FILE="/dump/db_dump.sql"
GLOBAL_DUMP_FILE="/dump/globals.sql"

# --- Helper functions --------------------------------------------------------

die() { log "Error: $*"; exit 1; }

# Cleanup function runs on EXIT (normal or error)
cleanup() {
  log "Cleaning up Docker containers, network, and temp files..."
  docker stop "$OLD_PG_CONTAINER" "$NEW_PG_CONTAINER" "$DUMP_CONTAINER" >/dev/null 2>&1 || true
  docker rm "$OLD_PG_CONTAINER" "$NEW_PG_CONTAINER" "$DUMP_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$DUMP_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  log "Cleanup completed."
}

# Restores original data directory from backup (runs once if backup exists)
restore_from_backup_once() {
  if (( BACKUP_TAKEN == 1 )) && (( RESTORE_ATTEMPTED == 0 )); then
    RESTORE_ATTEMPTED=1
    log "Restoring data directory from backup..."
    mkdir -p "$DATA_DIR"
    # Remove all files in target dir, but keep directory itself
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    rsync -a --delete "$TEMP_DIR/pgdata/" "$DATA_DIR/" || die "Failed to restore from backup."
    log "Data directory restored successfully."
  fi
}

# Error handler (runs automatically on ERR)
on_error() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  log "A failure occurred near line $line. Starting rollback (if backup available)..."
  restore_from_backup_once
  exit $exit_code
}

# Wrapper for commands — stops script if command fails
check_cmd() { "$@" || die "Command failed: $*"; }

# Waits for PostgreSQL container to be ready using pg_isready
wait_for_pg() {
  local container="$1" user="$2" retries=20 delay=3
  log "Waiting for PostgreSQL in container '$container' to start..."
  for ((i=1;i<=retries;i++)); do
    if docker exec -i "$container" pg_isready -U "$user" >/dev/null 2>&1; then
      log "PostgreSQL in '$container' is ready."
      return 0
    fi
    sleep "$delay"
  done
  die "PostgreSQL in '$container' failed to start after $((retries*delay)) seconds."
}

# --- Traps -------------------------------------------------------------------
trap on_error ERR
trap cleanup EXIT

# --- Main script logic -------------------------------------------------------

log "Starting PostgreSQL upgrade script..."

# Must be root or use sudo to ensure file and Docker access
if [[ "$EUID" -ne 0 ]]; then
  die "Please run this script as root or with sudo."
fi

# Validate arguments
if [[ -z "$DATA_DIR" || -z "$CURR_PG_VERSION" || -z "$NEW_PG_VERSION" ]]; then
  die "Usage: $0 <path_to_data_directory> <current_pg_version> <new_pg_version>"
fi

# Ensure data directory exists
[[ -d "$DATA_DIR" ]] || die "Data directory '$DATA_DIR' not found."

# Load environment variables from .env (required for DB credentials)
if [[ ! -f ".env" ]]; then
  die ".env file not found in $(pwd). Expected POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB."
fi

log "Loading .env file..."
set -o allexport
# shellcheck disable=SC1091
source .env
set +o allexport

# Ensure required variables are loaded
[[ -n "${POSTGRES_USER:-}" && -n "${POSTGRES_PASSWORD:-}" && -n "${POSTGRES_DB:-}" ]] \
  || die "Missing one or more required vars: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB"

# Check Docker is installed and running
command -v docker >/dev/null 2>&1 || die "Docker command not found."
check_cmd docker info >/dev/null 2>&1

# Pull required PostgreSQL Docker images
log "Pulling docker images for PostgreSQL $CURR_PG_VERSION and $NEW_PG_VERSION..."
check_cmd docker pull "postgres:${CURR_PG_VERSION}"
check_cmd docker pull "postgres:${NEW_PG_VERSION}"

# Step 1: Backup existing data safely
log "Backing up existing PostgreSQL data..."
mkdir -p "$TEMP_DIR/pgdata"
# Use rsync to copy data safely (handles empty dirs gracefully)
rsync -a --delete --ignore-missing-args "$DATA_DIR/" "$TEMP_DIR/pgdata/"
BACKUP_TAKEN=1
log "Backup completed and stored in $TEMP_DIR/pgdata"

# Step 2: Create a temporary Docker network (isolates containers)
log "Creating isolated Docker network for upgrade..."
check_cmd docker network create "$NETWORK_NAME"

# Step 3: Run the OLD Postgres container using the current data directory
log "Starting old PostgreSQL $CURR_PG_VERSION container..."
check_cmd docker run -d --name "$OLD_PG_CONTAINER" --network "$NETWORK_NAME" \
  -v "$DATA_DIR:/var/lib/postgresql/data" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  "postgres:${CURR_PG_VERSION}"

# Step 4: Wait for it to be ready
wait_for_pg "$OLD_PG_CONTAINER" "$POSTGRES_USER"

# Step 5: Create a volume to store dumps
log "Creating Docker volume for dumps..."
check_cmd docker volume create "$DUMP_VOLUME" >/dev/null

# Step 6: Run a helper (new version) container that will perform pg_dumpall
log "Starting helper container for dumps..."
check_cmd docker run -d --name "$DUMP_CONTAINER" --network "$NETWORK_NAME" \
  -v "$DUMP_VOLUME:/dump" \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "postgres:${NEW_PG_VERSION}" tail -f /dev/null

# Step 7: Dump globals (roles, etc.) and all databases
log "Dumping global roles and database data..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$DUMP_CONTAINER" \
  pg_dumpall -h "$OLD_PG_CONTAINER" -U "$POSTGRES_USER" -g -f "$GLOBAL_DUMP_FILE"

check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$DUMP_CONTAINER" \
  pg_dumpall -h "$OLD_PG_CONTAINER" -U "$POSTGRES_USER" -f "$DB_DUMP_FILE"

# Step 8: Stop and remove old container
log "Stopping and removing old PostgreSQL container..."
check_cmd docker stop "$OLD_PG_CONTAINER"
check_cmd docker rm "$OLD_PG_CONTAINER"

# Step 9: Wipe the old data directory (keep mount point)
log "Clearing old PostgreSQL data directory..."
find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# Step 10: Start the NEW PostgreSQL container
log "Starting new PostgreSQL $NEW_PG_VERSION container..."
check_cmd docker run -d --name "$NEW_PG_CONTAINER" --network "$NETWORK_NAME" \
  -v "$DATA_DIR:/var/lib/postgresql/data" \
  -v "$DUMP_VOLUME:/dump" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  "postgres:${NEW_PG_VERSION}"

# Step 11: Wait until the new instance is ready
wait_for_pg "$NEW_PG_CONTAINER" "$POSTGRES_USER"

# Step 12: Restore globals (roles, permissions) and database data
log "Restoring global roles and permissions..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$NEW_PG_CONTAINER" \
  psql -U "$POSTGRES_USER" -f "$GLOBAL_DUMP_FILE"

log "Restoring databases..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$NEW_PG_CONTAINER" \
  psql -U "$POSTGRES_USER" -f "$DB_DUMP_FILE"

# Step 13: Reindex system catalogs for new version
log "Reindexing system catalogs..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$NEW_PG_CONTAINER" \
  psql -U "$POSTGRES_USER" -c "REINDEX SYSTEM;"

log "✅ PostgreSQL upgrade completed successfully."
exit 0
