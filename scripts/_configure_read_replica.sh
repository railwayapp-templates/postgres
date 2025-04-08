#!/bin/bash

log "Starting read replica configuration"

if [ "$RAILWAY_PG_INSTANCE_TYPE" != "READREPLICA" ]; then
  log_err "\
This script can only be executed on a read replica instance. \
(expected: RAILWAY_PG_INSTANCE_TYPE='READREPLICA', \
received: RAILWAY_PG_INSTANCE_TYPE='$RAILWAY_PG_INSTANCE_TYPE')"
  exit 1
fi

rr_validate_node_id "$OUR_NODE_ID" || { exit 1; }

if [ -n "${REPMGR_USER_PWD+x}" ]; then
  log_err "\
REPMGR_USER_PWD must not be set for READREPLICA as it is a PRIMARY-only \
variable. Remove this from your service variables."
  exit 1
fi

if [ -n "${POSTGRES_PASSWORD+x}" ]; then
  log_err "\
POSTGRES_PASSWORD must not be set for READREPLICA as it is a PRIMARY-only \
variable. Remove this from your service variables."
  exit 1
fi

db_password_exists_in_connstring "DATABASE_URL" || {
  log_err "\
DATABASE_URL does not contain a valid password. Please ensure you have \
followed the set-up instructions for configuring read replicas."
  exit 1
}

db_password_exists_in_connstring "DATABASE_PUBLIC_URL" || {
  log_err "\
DATABASE_PUBLIC_URL does not contain a valid password. Please ensure you have \
followed the set-up instructions for configuring read replicas."
  exit 1
}

if [ -z "$PRIMARY_PGHOST" ]; then
  log_err "PRIMARY_PGHOST is required for read replica configuration."
  exit 1
fi

if [ -z "$PRIMARY_PGPORT" ]; then
  log_err "PRIMARY_PGPORT is required for read replica configuration."
  exit 1
fi

if [ -z "$PRIMARY_REPMGR_USER_PWD" ]; then
  log_err "PRIMARY_REPMGR_USER_PWD is required for read replica configuration."
  exit 1
fi

# Create repmgr configuration file
cat >"$REPMGR_CONF_FILE" <<EOF
node_id=${OUR_NODE_ID}
node_name='node${OUR_NODE_ID}'
conninfo='host=${RAILWAY_PRIVATE_DOMAIN} port=${PGPORT} user=repmgr dbname=repmgr connect_timeout=10 sslmode=disable'
data_directory='${PGDATA}'
use_replication_slots=yes
monitoring_history=yes
EOF
sudo chown postgres:postgres "$REPMGR_CONF_FILE"
sudo chmod 700 "$REPMGR_CONF_FILE"
log_ok "Created repmgr config ->> '$REPMGR_CONF_FILE'"

# Start clone process in background
export PGPASSWORD="$PRIMARY_REPMGR_USER_PWD" # for connecting to primary
su -m postgres -c \
  "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
   -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
   standby clone --force 2>&1" &
repmgr_pid=$!

log_ok "Performing clone of primary node. This may take awhile! ⏳"
while kill -0 $repmgr_pid 2>/dev/null; do
  echo -n "." # print progress indicator
  sleep 1
done
wait $repmgr_pid
repmgr_status=$?

if [ $repmgr_status -ne 0 ]; then
  log_err "Failed to clone primary node."
  exit 1
else
  log_ok "Successfully cloned primary node."
fi

log "Performing post-replication setup ⏳"

# Use primary connection for registering this replica. This requires the
# primary to be up and running!
if su -m postgres -c \
  "repmgr -h $PRIMARY_PGHOST -p $PRIMARY_PGPORT \
   -d repmgr -U repmgr -f $REPMGR_CONF_FILE \
   standby register --force 2>&1"; then
  log_ok "Successfully registered replica node."
else
  log_err "Failed to register replica node."
fi
