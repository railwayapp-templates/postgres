#!/bin/bash

log "Starting primary configuration"

if [ "$RAILWAY_PG_INSTANCE_TYPE" != "PRIMARY" ]; then
  log_err "\
This script can only be executed on a primary instance. \
(expected: RAILWAY_PG_INSTANCE_TYPE='PRIMARY', \
received: RAILWAY_PG_INSTANCE_TYPE='$RAILWAY_PG_INSTANCE_TYPE')"
  exit 1
fi

if [ -n "${OUR_NODE_ID+x}" ]; then
  log_err "\
OUR_NODE_ID must not be set for PRIMARY as it is a READREPLICA-only \
variable. Remove this from your service variables."
  exit 1
fi

if [ -z "$REPMGR_USER_PWD" ]; then
  log_err "REPMGR_USER_PWD is required for primary configuration."
  exit 1
fi

try_start_postgres

PG_REPLICATION_CONF_FILENAME="postgresql.replication.conf"
PG_REPLICATION_CONF_FILE="${PGDATA}/${PG_REPLICATION_CONF_FILENAME}"
PG_HBA_CONF_FILE="${PGDATA}/pg_hba.conf"

# Create repmgr user and database
log "Creating repmgr user and database ⏳"
if ! psql -c "SELECT 1 FROM pg_roles WHERE rolname='repmgr'" | grep -q 1; then
  psql -c "CREATE USER repmgr WITH SUPERUSER PASSWORD '${REPMGR_USER_PWD}';"
  log_ok "repmgr user created with password '***${REPMGR_USER_PWD: -4}'"
else
  log "repmgr user already exists"
fi

if ! psql -c "SELECT 1 FROM pg_database WHERE datname='repmgr'" | grep -q 1; then
  psql -c "CREATE DATABASE repmgr;"
  log_ok "Created repmgr database"
else
  log "repmgr database already exists"
fi

# Grant permissions to repmgr user
psql -c "GRANT ALL PRIVILEGES ON DATABASE repmgr TO repmgr;"
psql -c "ALTER USER repmgr SET search_path TO repmgr, railway, public;"

log_ok "repmgr database bootstrapped"

# Create repmgr configuration file
# (node_id is always 1 on primary)
cat >"$REPMGR_CONF_FILE" <<EOF
node_id=1
node_name='node1'
conninfo='host=${RAILWAY_PRIVATE_DOMAIN} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10'
data_directory='${PGDATA}'
use_replication_slots=yes
monitoring_history=yes
EOF
sudo chown postgres:postgres "$REPMGR_CONF_FILE"
sudo chmod 700 "$REPMGR_CONF_FILE"
log_ok "Created repmgr config ->> '$REPMGR_CONF_FILE'"

# Create replication configuration file
cat >"$PG_REPLICATION_CONF_FILE" <<EOF
wal_level = logical
wal_keep_size = 128MB
wal_log_hints = on
max_replication_slots = 5
max_wal_senders = 10
hot_standby = on
archive_mode = on
archive_command = '/bin/true'
EOF
sudo chown postgres:postgres "$PG_REPLICATION_CONF_FILE"
sudo chmod 700 "$PG_REPLICATION_CONF_FILE"
log_ok "Created Postgres replication config ->> '$PG_REPLICATION_CONF_FILE'"

# Modify PG_CONF_FILE to include replication conf
PG_CONF_FILE_BAK="${PG_CONF_FILE}.$(date +'%d-%m-%Y_%H-%M-%S').bak"
cp $PG_CONF_FILE $PG_CONF_FILE_BAK
log "Backed up '$PG_CONF_FILE' ->> '$PG_CONF_FILE_BAK'"

if ! grep -q "include '$PG_REPLICATION_CONF_FILENAME'" "$PG_CONF_FILE"; then
  echo "" >>"$PG_CONF_FILE"
  echo "# Added by Railway on $(date +'%Y-%m-%d %H:%M:%S') [via: $SH_CONFIGURE_PRIMARY]" \
    >>"$PG_CONF_FILE"
  echo "include '$PG_REPLICATION_CONF_FILENAME'" >>"$PG_CONF_FILE"
  log_ok "Added include directive for replication conf to '$PG_CONF_FILE'"
else
  log "Include directive for replication conf already present in '$PG_CONF_FILE'"
fi

# Register primary node
log "Registering primary node with repmgr ⏳"
export PGPASSWORD="$REPMGR_USER_PWD"
if su -m postgres -c "repmgr -f $REPMGR_CONF_FILE primary register"; then
  log_ok "Successfully registered primary node"

  # Modify pg_hba.conf to allow replication access
  LAST_LINE=$(tail -n 1 "$PG_HBA_CONF_FILE")
  if [ "$LAST_LINE" != "host all all all scram-sha-256" ]; then
    log_err "\
The contents of pg_hba.conf is not as expected. Modification will be skipped \
to avoid corrupting configuration. Manual intervention is required to fix \
this issue. (expected 'host all all all scram-sha-256', received '$LAST_LINE')"
    exit 1
  else
    PG_HBA_CONF_FILE_BAK="${PG_HBA_CONF_FILE}.$(date +'%d-%m-%Y_%H-%M-%S').bak"
    cp $PG_HBA_CONF_FILE $PG_HBA_CONF_FILE_BAK
    log "Backed up '$PG_HBA_CONF_FILE' ->> '$PG_HBA_CONF_FILE_BAK'"

    # Create temporary file with the desired content
    _TMPFILE=$(mktemp)
    # Get all lines except the last one
    head -n -1 "$PG_HBA_CONF_FILE" >"$_TMPFILE"
    # Add our new line
    echo "# Added by Railway on $(date +'%Y-%m-%d %H:%M:%S') [via: $SH_CONFIGURE_PRIMARY]" \
      >>"$_TMPFILE"
    echo "host replication repmgr ::0/0 trust" >>"$_TMPFILE"
    # Add the last line back
    echo "host all all all scram-sha-256" >>"$_TMPFILE"

    # Replace the original file
    mv "$_TMPFILE" "$PG_HBA_CONF_FILE"
    sudo chown postgres:postgres "$PG_HBA_CONF_FILE"
    sudo chmod 700 "$PG_HBA_CONF_FILE"

    log_ok "Updated '$PG_HBA_CONF_FILE' with replication access."
  fi
  log_ok "Primary configuration complete."
else
  log_err "Failed to register primary node with repmgr."
fi

stop_postgres
