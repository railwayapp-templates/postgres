#!/bin/bash
set -Eeo pipefail

SH_INCLUDE="/usr/local/bin/_include.sh"
SH_CONFIGURE_SSL="/usr/local/bin/_configure_ssl.sh"
SH_CONFIGURE_PRIMARY="/usr/local/bin/_configure_primary.sh"
SH_CONFIGURE_READ_REPLICA="/usr/local/bin/_configure_read_replica.sh"

source "$SH_INCLUDE"

echo ""
log_warn "\
This is an ALPHA version of the Railway Postgres image. Please do not use \
this version unless advised by the Railway team. If you choose to use this \
version without support from Railway, you accept that you are doing so at \
your own risk, and Railway is not responsible for any data loss or \
corruption that may occur as a result of ignoring this warning."
echo ""

if [ ! -z "$DEBUG_MODE" ]; then
  log "Starting in debug mode! Postgres will not run."
  log "The container will stay alive and be shell-accessible."
  trap "echo Shutting down; exit 0" SIGTERM SIGINT SIGKILL
  sleep infinity &
  wait
fi

if [ -z "$RAILWAY_VOLUME_NAME" ]; then
  log_err "\
Missing RAILWAY_VOLUME_NAME! Please ensure that you have a volume attached \
to your service."
  exit 1
fi

if [ -z "$RAILWAY_VOLUME_MOUNT_PATH" ]; then
  log_err "\
Missing RAILWAY_VOLUME_MOUNT_PATH! Please ensure that you have a volume \
attached to your service."
  exit 1
fi

if [ -z "$RAILWAY_PG_INSTANCE_TYPE" ]; then
  log_err "RAILWAY_PG_INSTANCE_TYPE is required to use this image."
  exit 1
fi

# PGDATA dir
PGDATA="${RAILWAY_VOLUME_MOUNT_PATH}/pgdata"
mkdir -p "$PGDATA"
sudo chown -R postgres:postgres "$PGDATA"
sudo chmod 700 "$PGDATA"

# Certs dir
SSL_CERTS_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/certs"
mkdir -p "$SSL_CERTS_DIR"
sudo chown -R postgres:postgres "$SSL_CERTS_DIR"
sudo chmod 700 "$SSL_CERTS_DIR"

# Repmgr dir
REPMGR_DIR="${RAILWAY_VOLUME_MOUNT_PATH}/repmgr"
mkdir -p "$REPMGR_DIR"
sudo chown -R postgres:postgres "$REPMGR_DIR"
sudo chmod 700 "$REPMGR_DIR"

# File paths
PG_CONF_FILE="${PGDATA}/postgresql.conf"
REPMGR_CONF_FILE="${REPMGR_DIR}/repmgr.conf"
SETUP_LOCK_FILE="${RAILWAY_VOLUME_MOUNT_PATH}/setup.lock"

if [ -f "$SETUP_LOCK_FILE" ]; then
  PREVIOUS_INSTANCE_TYPE=$(cat "$SETUP_LOCK_FILE")
  if [ "$PREVIOUS_INSTANCE_TYPE" = "READREPLICA" ] &&
    [ "$RAILWAY_PG_INSTANCE_TYPE" = "PRIMARY" ]; then
    log_err "Instance type change from READREPLICA to PRIMARY is not supported."
    exit 1
  fi
  if [ "$PREVIOUS_INSTANCE_TYPE" = "PRIMARY" ] &&
    [ "$RAILWAY_PG_INSTANCE_TYPE" = "READREPLICA" ]; then
    log_err "Instance type change from PRIMARY to READREPLICA is not supported."
    exit 1
  fi
fi

case "$RAILWAY_PG_INSTANCE_TYPE" in
"READREPLICA")
  rr_validate_node_id "$OUR_NODE_ID" || {
    exit 1
  }
  log_hl "Running as READREPLICA (nodeid=$OUR_NODE_ID)"

  # Configure as read replica if not already configured
  if [ -f "$SETUP_LOCK_FILE" ] &&
    [ "$(cat "$SETUP_LOCK_FILE")" = "READREPLICA" ]; then
    LOCK_FILE_CREATION_TIMESTAMP=$(stat -c %w "$SETUP_LOCK_FILE")
    log "READREPLICA is configured (timestamp: ${LOCK_FILE_CREATION_TIMESTAMP})"
  else
    source "$SH_CONFIGURE_READ_REPLICA"
    echo "READREPLICA" >"$SETUP_LOCK_FILE"
  fi
  ;;
"PRIMARY")
  log_hl "Running as PRIMARY (nodeid=1)"

  # Configure as primary if not already configured
  if [ -f "$SETUP_LOCK_FILE" ] &&
    [ "$(cat "$SETUP_LOCK_FILE")" = "PRIMARY" ]; then
    LOCK_FILE_CREATION_TIMESTAMP=$(stat -c %w "$SETUP_LOCK_FILE")
    log "PRIMARY is configured (timestamp: ${LOCK_FILE_CREATION_TIMESTAMP})"
  else
    source "$SH_CONFIGURE_PRIMARY"
    echo "PRIMARY" >"$SETUP_LOCK_FILE"
  fi
  ;;
*) ;;
esac

source "$SH_CONFIGURE_SSL"
/usr/local/bin/docker-entrypoint.sh "$@"
