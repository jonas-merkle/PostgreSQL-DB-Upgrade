#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PostgreSQL Docker Upgrade Script
#
# Safely upgrades a PostgreSQL database using Docker by dump/restore:
#   1) Validate args, .env, Docker, and host data directory (no side effects).
#   2) Snapshot backup to a temp folder.
#   3) Run OLD version on existing data; dump globals + all DBs.
#   4) Stop OLD, clear contents (keep mount), start NEW, restore dumps.
#   5) Reindex; cleanup containers/network/temp files.
#
# - This script NEVER changes file ownership/permissions. If they look wrong,
#   it exits with clear instructions on how to fix them yourself.
#
# - Optional: On SELinux systems, run with SELINUX_LABEL=true to add :Z to mounts.
#
# License Information:
# Copyright (C) 2025 [Jonas Merkle [JJM]](mailto:jonas@jjm.one?subject=%5BGitHub%5D%3A%20PostgreSQL%20DB%20Upgrade)
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
# ---------------------------------------------------------------------------

set -Eeuo pipefail

log(){ printf '%s - %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
die(){ log "Error: $*"; exit 1; }

# --- Arguments ---------------------------------------------------------------
DATA_DIR="${1:-}"
CURR_PG_VERSION="${2:-}"
NEW_PG_VERSION="${3:-}"

# Resolve to absolute path to avoid surprises with ../ etc.
if [[ -n "${DATA_DIR}" && "${DATA_DIR:0:1}" != "/" ]]; then
  DATA_DIR="$(readlink -f "$DATA_DIR")"
fi

# --- Config knobs ------------------------------------------------------------
# On SELinux hosts (Fedora/RHEL/CentOS), set SELINUX_LABEL=true to add :Z to bind mounts.
SELINUX_LABEL=${SELINUX_LABEL:-false}

# Default UID/GID used by the official postgres image is 999:999.
# We DO NOT change ownership. We only check and warn/exit.
EXPECTED_PG_UID="${EXPECTED_PG_UID:-999}"
EXPECTED_PG_GID="${EXPECTED_PG_GID:-999}"

mount_opt_suffix(){
  if [[ "$SELINUX_LABEL" == "true" ]]; then
    printf ':Z'
  else
    printf ''
  fi
}

# Compute the in-container PGDATA path/volume target for a given version
pgdata_target_for_version(){
  local ver="$1"
  # Numeric compare; assumes simple major version integers
  if (( ver >= 18 )); then
    echo "/var/lib/postgresql/18/docker"
  else
    echo "/var/lib/postgresql/data"
  fi
}

# --- Runtime names -----------------------------------------------------------
TEMP_DIR="$(mktemp -d)"
BACKUP_TAKEN=0
RESTORE_ATTEMPTED=0

NETWORK_NAME="pg_upgrade_net_$RANDOM"
OLD_PG_CONTAINER="pg_old_${CURR_PG_VERSION}_$RANDOM"
NEW_PG_CONTAINER="pg_new_${NEW_PG_VERSION}_$RANDOM"
DUMP_CONTAINER="pg_dump_container_$RANDOM"
DUMP_VOLUME="pg_dump_volume_$RANDOM"

DB_DUMP_FILE="/dump/db_dump.sql"
GLOBAL_DUMP_FILE="/dump/globals.sql"

# --- Helpers -----------------------------------------------------------------
cleanup(){
  log "Cleaning up Docker containers, network, and temp files..."
  docker stop "$OLD_PG_CONTAINER" "$NEW_PG_CONTAINER" "$DUMP_CONTAINER" >/dev/null 2>&1 || true
  docker rm   "$OLD_PG_CONTAINER" "$NEW_PG_CONTAINER" "$DUMP_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$DUMP_VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  log "Cleanup completed."
}

restore_from_backup_once(){
  if (( BACKUP_TAKEN == 1 )) && (( RESTORE_ATTEMPTED == 0 )); then
    RESTORE_ATTEMPTED=1
    log "Restoring data directory from backup..."
    # Keep mount point; repopulate contents from backup snapshot
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    rsync -a --delete "$TEMP_DIR/pgdata/" "$DATA_DIR/" || die "Failed to restore from backup."
    log "Data directory restored successfully."
  fi
}

on_error(){
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  log "A failure occurred near line $line. Rolling back if possible…"
  restore_from_backup_once
  exit $exit_code
}

check_cmd(){ "$@" || die "Command failed: $*"; }

wait_for_pg(){
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

# --- Host data dir checks (no changes are made) ------------------------------
verify_host_datadir(){
  # 1) Must exist (we do NOT create it to avoid side-effects)
  [[ -n "$DATA_DIR" ]] || die "Missing data directory argument."
  [[ -d "$DATA_DIR" ]] || die "Data directory '$DATA_DIR' does not exist. Create it and ensure proper ownership (see below)."

  # 2) Ownership sanity (common source of container startup failures)
  local uid gid
  uid="$(stat -c '%u' "$DATA_DIR" 2>/dev/null || echo unknown)"
  gid="$(stat -c '%g' "$DATA_DIR" 2>/dev/null || echo unknown)"
  if [[ "$uid" != "$EXPECTED_PG_UID" || "$gid" != "$EXPECTED_PG_GID" ]]; then
    cat <<EOF
$(date +'%Y-%m-%d %H:%M:%S') - Warning: '$DATA_DIR' is owned by UID:GID ${uid}:${gid}, not ${EXPECTED_PG_UID}:${EXPECTED_PG_GID}.
This often prevents 'postgres:${NEW_PG_VERSION}' from starting when the directory is bind-mounted.

How to fix:
  sudo chown ${EXPECTED_PG_UID}:${EXPECTED_PG_GID} "$DATA_DIR"

If you're on SELinux (Fedora/RHEL/CentOS), you may also need to relabel the path:
  (Option A) Add :Z to the mount (set SELINUX_LABEL=true when running this script)
  (Option B) Or label the directory manually:
      sudo chcon -Rt svirt_sandbox_file_t "$DATA_DIR"

No changes were made. Exiting to prevent partial upgrades.
EOF
    exit 1
  fi

  # 3) Bind-mount preflight: ensure Docker can mount and write inside it.
  log "Probing Docker bind mount for $DATA_DIR..."
  local probe_cmd="touch /mnt/.probe.$$ && echo ok >/mnt/.probe.$$ && cat /mnt/.probe.$$ && rm -f /mnt/.probe.$$"
  if ! docker run --rm -v "${DATA_DIR}:/mnt$(mount_opt_suffix)" busybox sh -c "$probe_cmd" | grep -qx 'ok'; then
    cat <<EOF
$(date +'%Y-%m-%d %H:%M:%S') - Error: Docker could not bind-mount '$DATA_DIR' for read/write access.

Troubleshooting tips:
  - Verify permissions and ownership: expecting UID:GID ${EXPECTED_PG_UID}:${EXPECTED_PG_GID}
  - On SELinux systems, try again with: SELINUX_LABEL=true sudo ./upgrade_postgresql_db.sh ...
  - Ensure the path is a real directory (not a broken symlink) and your Docker daemon
    has access to the parent path (Docker Desktop file-sharing, or daemon permissions).

No changes were made. Exiting to prevent partial upgrades.
EOF
    exit 1
  fi
  log "Bind mount probe succeeded."
}

# --- Traps -------------------------------------------------------------------
trap on_error ERR
trap cleanup EXIT

# --- Main --------------------------------------------------------------------
log "Starting PostgreSQL upgrade script..."

# Privilege check (Docker + filesystem operations generally need root)
if [[ "$EUID" -ne 0 ]]; then
  die "Please run this script as root or with sudo."
fi

# Validate args
if [[ -z "$DATA_DIR" || -z "$CURR_PG_VERSION" || -z "$NEW_PG_VERSION" ]]; then
  die "Usage: $0 <path_to_data_directory> <current_pg_version> <new_pg_version>"
fi

# .env must exist in CWD and define creds
if [[ ! -f ".env" ]]; then
  die ".env not found in $(pwd). Expected POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB."
fi

log "Loading .env file..."
set -o allexport
# shellcheck disable=SC1091
source .env
set +o allexport

[[ -n "${POSTGRES_USER:-}" && -n "${POSTGRES_PASSWORD:-}" && -n "${POSTGRES_DB:-}" ]] \
  || die "Missing required vars in .env: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB"

# Docker sanity
command -v docker >/dev/null 2>&1 || die "Docker not found in PATH."
check_cmd docker info >/dev/null 2>&1

# Verify host data dir (exists, expected ownership, mountable)
verify_host_datadir

# Pull images early (fail fast if unavailable)
log "Pulling docker images for PostgreSQL $CURR_PG_VERSION and $NEW_PG_VERSION..."
check_cmd docker pull "postgres:${CURR_PG_VERSION}"
check_cmd docker pull "postgres:${NEW_PG_VERSION}"

# Backup current data (snapshot to temp)
log "Backing up existing PostgreSQL data..."
mkdir -p "$TEMP_DIR/pgdata"
rsync -a --delete --ignore-missing-args "$DATA_DIR/" "$TEMP_DIR/pgdata/"
BACKUP_TAKEN=1
log "Backup completed and stored in $TEMP_DIR/pgdata"

# Isolated network
log "Creating isolated Docker network for upgrade..."
check_cmd docker network create "$NETWORK_NAME"

# --- Start OLD Postgres (mount to the OLD version's default in-container path) ---
OLD_PGDATA_PATH="$(pgdata_target_for_version "$CURR_PG_VERSION")"
log "Starting old PostgreSQL $CURR_PG_VERSION container (PGDATA=${OLD_PGDATA_PATH})..."
check_cmd docker run -d --name "$OLD_PG_CONTAINER" --network "$NETWORK_NAME" \
  -v "$DATA_DIR:${OLD_PGDATA_PATH}$(mount_opt_suffix)" \
  -e PGDATA="$OLD_PGDATA_PATH" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  "postgres:${CURR_PG_VERSION}"

# Wait for readiness
wait_for_pg "$OLD_PG_CONTAINER" "$POSTGRES_USER"

# Dump volume + helper container (uses NEW image tools)
log "Creating Docker volume for dumps..."
check_cmd docker volume create "$DUMP_VOLUME" >/dev/null

log "Starting helper container for dumps..."
check_cmd docker run -d --name "$DUMP_CONTAINER" --network "$NETWORK_NAME" \
  -v "$DUMP_VOLUME:/dump" \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "postgres:${NEW_PG_VERSION}" tail -f /dev/null

# Create dumps: globals then everything
log "Dumping global roles and database data..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$DUMP_CONTAINER" \
  pg_dumpall -h "$OLD_PG_CONTAINER" -U "$POSTGRES_USER" -g -f "$GLOBAL_DUMP_FILE"

check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$DUMP_CONTAINER" \
  pg_dumpall -h "$OLD_PG_CONTAINER" -U "$POSTGRES_USER" -f "$DB_DUMP_FILE"

# Stop/remove old container
log "Stopping and removing old PostgreSQL container..."
check_cmd docker stop "$OLD_PG_CONTAINER"
check_cmd docker rm "$OLD_PG_CONTAINER"

# Clear contents of the data dir (keep mount point)
log "Clearing old PostgreSQL data directory (keeping mount point)..."
find "$DATA_DIR" -mindepth 1 -exec rm -rf {} +
# Small delay to avoid overlay/propagation race conditions on some kernels
sleep 1

# --- Start NEW Postgres (mount to the NEW version's default PGDATA path) ---
NEW_PGDATA_PATH="$(pgdata_target_for_version "$NEW_PG_VERSION")"
log "Starting new PostgreSQL $NEW_PG_VERSION container (PGDATA=${NEW_PGDATA_PATH})..."
check_cmd docker run -d --name "$NEW_PG_CONTAINER" --network "$NETWORK_NAME" \
  -v "$DATA_DIR:${NEW_PGDATA_PATH}$(mount_opt_suffix)" \
  -v "$DUMP_VOLUME:/dump" \
  -e PGDATA="$NEW_PGDATA_PATH" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  "postgres:${NEW_PG_VERSION}"

# Wait for readiness
wait_for_pg "$NEW_PG_CONTAINER" "$POSTGRES_USER"

# Restore globals and databases
log "Restoring global roles and permissions..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$NEW_PG_CONTAINER" \
  psql -U "$POSTGRES_USER" -f "$GLOBAL_DUMP_FILE"

log "Restoring databases..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$NEW_PG_CONTAINER" \
  psql -U "$POSTGRES_USER" -f "$DB_DUMP_FILE"

# Reindex system catalogs
log "Reindexing system catalogs..."
check_cmd docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -i "$NEW_PG_CONTAINER" \
  psql -U "$POSTGRES_USER" -c "REINDEX SYSTEM;"

log "✅ PostgreSQL upgrade completed successfully."
exit 0
