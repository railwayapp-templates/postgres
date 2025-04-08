# 🚧 Railway Postgres (alpha)

> ⚠️ This is under development. All code within this repository is released
> under an `alpha` tag. Please do not use these versions unless advised by the
> Railway team.

## Features

- Replication support via [repmgr](https://repmgr.org)
- Automatic SSL cert generation and renewal

## Usage

There is no Railway template for this yet. In its current iteration, this is
meant to **replace the base image** of an existing Postgres service deployed
on Railway. Doing so will transparently upgrade the Postgres service to
support replication, and allow you to create read replicas of the primary.

The setup steps here are manual. We're working on baking this into the product
in the future.

Before proceeding:

- Please ensure you have [backups](https://docs.railway.com/reference/backups)
  enabled
- If you have requested a volume size increase for your Postgres service in
  the past, please let us know so we can ensure your read replica has the same
  volume size
- Your primary Postgres service will be re-deployed. This will incur some
  downtime (<1 minute) while the new deployment is being created

### Primary Configuration

On the Postgres service you wish to designate as the primary:

1. Change the image under `Settings -> Source -> Source Image`. Use the image
   corresponding to the current version you are on:

   | Current Source Image...                      | Change Source Image To...                           |
   | -------------------------------------------- | --------------------------------------------------- |
   | ghcr.io/railwayapp-templates/postgres-ssl:15 | ghcr.io/railwayapp-templates/postgres:pg15.12-alpha |
   | ghcr.io/railwayapp-templates/postgres-ssl:16 | ghcr.io/railwayapp-templates/postgres:pg16.8-alpha  |
   | ghcr.io/railwayapp-templates/postgres-ssl:17 | ghcr.io/railwayapp-templates/postgres:pg17.4-alpha  |

2. Make the following changes to your service variables:

   | Action | Variable                 | Value                                                                                                                               |
   | ------ | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
   | + Add  | RAILWAY_PG_INSTANCE_TYPE | PRIMARY                                                                                                                             |
   | + Add  | REPMGR_USER_PWD          | Strong password (tip: use CMD+K -> Generate 32 character secret on Railway dashboard to generate a strong value that you can paste) |

   Your primary's service variables should resemble this diff:

   ```diff
   DATABASE_PUBLIC_URL="postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/${{PGDATABASE}}"
   DATABASE_URL="postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}"
   PGDATA="/var/lib/postgresql/data/pgdata"
   PGDATABASE="${{POSTGRES_DB}}"
   PGHOST="${{RAILWAY_PRIVATE_DOMAIN}}"
   PGPASSWORD="${{POSTGRES_PASSWORD}}"
   PGPORT="5432"
   PGUSER="${{POSTGRES_USER}}"
   POSTGRES_DB="railway"
   POSTGRES_PASSWORD="redacted"
   POSTGRES_USER="postgres"
   RAILWAY_DEPLOYMENT_DRAINING_SECONDS="60"
   SSL_CERT_DAYS="820"
   + RAILWAY_PG_INSTANCE_TYPE="PRIMARY"
   + REPMGR_USER_PWD="$SOME_STRONG_PASSWORD"
   ```

3. Click "Apply Changes". This will re-deploy your Postgres service with the
   new image and configure it as the primary. Once the new deployment is Active,
   follow the steps below to create read replicas

### Creating Read Replicas

1. Duplicate the primary service from above (right click service -> `Duplicate`)

2. Adjust the duplicated service's variables:

   | Action   | Variable                 | Value                                                                                                                                                                                                                                        |
   | -------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
   | + Add    | OUR_NODE_ID              | A unique integer ≥2. The primary node is always `node1` and subsequent nodes must be numbered starting from `2`. If this is your first read replica, set it to `2`, otherwise increment it by 1 for each additional read replica you create. |
   | + Add    | PRIMARY_REPMGR_USER_PWD  | Set to the value of `REPMGR_USER_PWD` on the primary instance using [Reference Variables](https://docs.railway.com/reference/variables#reference-variables)                                                                                  |
   | + Add    | PRIMARY_PGHOST           | Set to the PGHOST of the primary instance using [Reference Variables](https://docs.railway.com/reference/variables#reference-variables)                                                                                                      |
   | + Add    | PRIMARY_PGPORT           | Set to the PGPORT of the primary instance using [Reference Variables](https://docs.railway.com/reference/variables#reference-variables)                                                                                                      |
   | ~ Change | RAILWAY_PG_INSTANCE_TYPE | READREPLICA                                                                                                                                                                                                                                  |
   | ~ Change | DATABASE_URL             | Replace `${{POSTGRES_PASSWORD}}` in `DATABASE_URL` with `${{PGPASSWORD}}`                                                                                                                                                                    |
   | ~ Change | DATABASE_PUBLIC_URL      | Replace `${{POSTGRES_PASSWORD}}` in `DATABASE_URL` with `${{PGPASSWORD}}`                                                                                                                                                                    |
   | ~ Change | PGPASSWORD               | Set to PGPASSWORD of the primary instance using [Reference Variables](https://docs.railway.com/reference/variables#reference-variables)                                                                                                      |
   | - Remove | POSTGRES_PASSWORD        | -                                                                                                                                                                                                                                            |

   Your read replica's service variables should resemble this diff:

   ```diff
   + DATABASE_PUBLIC_URL="postgresql://${{PGUSER}}:${{PGPASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/${{PGDATABASE}}"
   - DATABASE_PUBLIC_URL="postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/${{PGDATABASE}}"
   + DATABASE_URL="postgresql://${{PGUSER}}:${{PGPASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}"
   - DATABASE_URL="postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}"
   + OUR_NODE_ID="2"
   PGDATA="/var/lib/postgresql/data/pgdata"
   PGDATABASE="${{POSTGRES_DB}}"
   PGHOST="${{RAILWAY_PRIVATE_DOMAIN}}"
   - PGPASSWORD="${{POSTGRES_PASSWORD}}"
   + PGPASSWORD="${{Postgres-Primary.PGPASSWORD}}"
   PGPORT="5432"
   PGUSER="${{POSTGRES_USER}}"
   POSTGRES_DB="railway"
   POSTGRES_USER="postgres"
   - POSTGRES_PASSWORD="redacted"
   + PRIMARY_PGHOST="${{Postgres-Primary.PGHOST}}"
   + PRIMARY_PGPORT="${{Postgres-Primary.PGPORT}}"
   + PRIMARY_REPMGR_USER_PWD="${{Postgres-Primary.REPMGR_USER_PWD}}"
   - REPMGR_USER_PWD="redacted"
   RAILWAY_DEPLOYMENT_DRAINING_SECONDS="60"
   + RAILWAY_PG_INSTANCE_TYPE="READREPLICA"
   - RAILWAY_PG_INSTANCE_TYPE="PRIMARY"
   SSL_CERT_DAYS="820"
   ```

3. Click "Apply Changes". This will deploy your read replica. The initial
   setup may take some time depending on the size of your primary
   instance. You can monitor the logs of the read replica to see when it is
   ready

To create more read replicas, repeat the steps above on Creating Read Replicas.

### Notes

- Failovers are not supported at this time
- Read replicas share the same credentials as the primary instance. You can
  connect to it using the same credentials as the primary instance
- Read replicas are strictly read-only. You cannot write to them. Attempting
  to do so will result in a Postgres error `ERROR:  cannot execute INSERT in a read-only transaction`
- If you are using a connection pooler such as pgbouncer, consider setting a
  separate instance for your read replica as well, or use a replication-aware
  connection pooler such as [pgpool](https://www.pgpool.net/mediawiki/index.php/Main_Page)
- If your ORM supports it, you can use the read replica's connection string
  directly for read-only statements (e.g. [Prisma](https://www.prisma.io/docs/orm/prisma-client/setup-and-configuration/read-replicas))

### Using repmgr

Replication is set up using [repmgr](https://repmgr.org/). All repmgr commands
are available.

1. Set up Railway CLI ([https://docs.railway.com/guides/cli](https://docs.railway.com/guides/cli)]
2. Right click the service you wish to run repmgr commands on
3. Click "Copy SSH Command" ([https://docs.railway.com/reference/cli-api#ssh](https://docs.railway.com/reference/cli-api#ssh))
4. Paste into a Terminal

This will open a shell into your service's container. From there, you can run:

```sh
# Use the Postgres user:
su -m postgres

# Make repmgr use the repmgr user:
export PGPASSWORD="${REPMGR_USER_PWD}"
repmgr -U repmgr -f /var/lib/postgresql/data/repmgr/repmgr.conf cluster show

# To run other repmgr commands:
repmgr -U repmgr -f /var/lib/postgresql/data/repmgr/repmgr.conf <REPMGR_COMMAND>
```

(You may notice a `bash: /root/.bashrc: Permission denied` error after
running `su -m postgres`. This is expected and can be safely ignored.)

## Changelog

#### 2025-04-07

🚀 Initial release ([`🔀 head=e6d147 @ railwayapp-templates/postgres-ssl`](https://github.com/railwayapp-templates/postgres-ssl/commit/e6d147e5f4e3c4b6e07f166643c4b19d902cee4a))

- Adds support for setting up replication via [repmgr](https://repmgr.org/)
- Postgres versions are now pinned to their respective latest minor versions
  and `bookworm` deb images
- `SSL_CERT_DAYS` is deprecated. This value will be ignored if provided. All
  server certificates will default to 730 days validity
- Root CA certificate expiry is now separated from server certificate expiry
- Adds `DEBUG_MODE` environment variable. When set, the container will
  `sleep infinity;` so it remains shell-accessible instead of starting
  Postgres
- Require `RAILWAY_VOLUME_NAME` and `RAILWAY_VOLUME_MOUNT_PATH`
  environment variables to be set to avoid deployments without a volume
  on Railway
