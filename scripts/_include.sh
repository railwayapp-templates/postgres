#!/bin/bash

# ANSI colors
GREEN_R='\033[0;32m'
GREEN_B='\033[1;92m'
RED_R='\033[0;31m'
RED_B='\033[1;91m'
YELLOW_R='\033[0;33m'
YELLOW_B='\033[1;93m'
PURPLE_R='\033[0;35m'
PURPLE_B='\033[1;95m'
WHITE_R='\033[0;37m'
WHITE_B='\033[1;97m'
NC='\033[0m'

# Logging functions
log() {
  echo -e "[ ${WHITE_R}ℹ️ INFO${NC} ] ${WHITE_B}$1${NC}"
}

log_hl() {
  echo -e "[ ${PURPLE_R}ℹ️ INFO${NC} ] ${PURPLE_B}$1${NC}"
}

log_ok() {
  echo -e "[ ${GREEN_R}✅ OK${NC}   ] ${GREEN_B}$1${NC}"
}

log_warn() {
  echo -e "[ ${YELLOW_R}⚠️ WARN${NC} ] ${YELLOW_B}$1${NC}"
}

log_err() {
  echo -e "[ ${RED_R}⛔ ERR${NC}  ] ${RED_B}$1${NC}" >&2
}

# _wait_for_postgres_start() waits for the Postgres process to start.
#
# Example usage:
#
#   if wait_for_postgres_start; then
#     echo "Postgres started"
#   else
#     echo "Postgres failed to start"
#     exit 1
#   fi
_wait_for_postgres_start() {
  local sleep_time=3
  local max_attempts=10
  local attempt=1

  log "Waiting for Postgres to start ⏳"

  while [ $attempt -le $max_attempts ]; do
    log "\
Postgres is not ready. Re-trying in $sleep_time seconds \
(attempt $attempt/$max_attempts)"

    if psql $connection_string -c "SELECT 1;" >/dev/null 2>&1; then
      log_ok "Postgres is up and running!"
      return 0
    fi
    sleep $sleep_time
    attempt=$((attempt + 1))
  done

  log_err "\
Timed out waiting for Postgres to start! \
(exceeded $((max_attempts * sleep_time)) seconds)"

  return 1
}

# _wait_for_postgres_stop() waits for a running Postgres process to stop.
#
# Example usage:
#
#   if wait_for_postgres_stop; then
#     echo "Postgres stopped"
#   else
#     echo "Postgres failed to stop"
#     exit 1
#   fi
_wait_for_postgres_stop() {
  local sleep_time=3
  local max_attempts=10
  local attempt=1

  log "Waiting for Postgres to stop ⏳"

  while [ $attempt -le $max_attempts ]; do
    if ! pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
      return 0
    fi

    log "\
Postgres is still shutting down. \
Re-checking in $sleep_time seconds (attempt $attempt/$max_attempts)"

    sleep $sleep_time
    attempt=$((attempt + 1))
  done

  log_err "\
Timed out waiting for Postgres to stop! \
(exceeded $((max_attempts * sleep_time)) seconds)"

  return 1
}

# try_start_postgres() attempts to start the Postgres process if it is not
# already running.
try_start_postgres() {
  if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    log_ok "Postgres is up and running!"
  else
    log_hl "Starting Postgres ⏳"
    su -m postgres -c "pg_ctl -D ${PGDATA} start"

    # Wait for Postgres to be ready after starting
    _wait_for_postgres_start || {
      log_err "Failed to start Postgres properly. Exiting."
      exit 1
    }
  fi
}

# stop_postgres() attempts to stop the Postgres process gracefully. If it
# cannot stop gracefully, it will attempt to force stop the process.
stop_postgres() {
  log_hl "Stopping Postgres ⏳"
  su -m postgres -c "pg_ctl -D ${PGDATA} stop -m fast"

  # Wait for Postgres to fully stop
  _wait_for_postgres_stop || {
    # Force stop as a last resort if needed
    log_err "Postgres did not stop cleanly. Manual intervention may be required."
    log_warn "Attempting to force stop Postgres."
    su -m postgres -c "pg_ctl -D ${PGDATA} stop -m immediate" || true
    sleep 5
  }

  # Verify Postgres has stopped
  if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    log_warn "Postgres is still running despite stop attempts!"
  else
    log_ok "Postgres stopped."
  fi
}

# db_password_exists_in_connstring() checks if a provided environment variable
# containing a database connection URL has a password.
#
# Arguments:
#   $1 - The name of the environment variable containing the database URL
#
# Returns:
#   0 (success) if password is present
#   1 (failure) if no password is found
#   2 (error) if environment variable is not set or URL format is invalid
#
# Example usage:
#
#   export DATABASE_URL="postgresql://postgres:password@localhost:5432/dbname"
#   if db_password_exists_in_connstring "DATABASE_URL"; then
#     echo "Password exists"
#   else
#     echo "No password or error"
#   fi
db_password_exists_in_connstring() {
  local env_var_name="$1"

  if [ -z "$env_var_name" ]; then
    log_err "Environment variable name must be provided"
    return 2
  fi

  local db_url="${!env_var_name}"

  if [ -z "$db_url" ]; then
    log_err "Provided environment variable '$env_var_name' is unset"
    return 2
  fi

  if [[ $db_url =~ ://[^:]+:([^@]*)@ ]]; then
    local password="${BASH_REMATCH[1]}"
    if [ -z "$password" ]; then
      return 1
    else
      return 0
    fi
  else
    log_err "Could not parse database URL format"
    return 2
  fi
}

# rr_validate_node_id() checks if the provided node ID is valid in READREPLICA
# mode.
#
# Example usage:
#   validate_node_id "$OUR_NODE_ID" || exit 1
rr_validate_node_id() {
  local node_id="$1"
  if ! [[ "$node_id" =~ ^[0-9]+$ ]] || [ "$node_id" -lt 2 ]; then
    log_err "\
OUR_NODE_ID is required in READREPLICA mode. It must be an integer ≥2. \
The primary node is always 'node1' and subsequent nodes must be numbered \
starting from 2. (received OUR_NODE_ID='$node_id')\
"
    return 1
  fi
  return 0
}
