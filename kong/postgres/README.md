#
``` Install Docker
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg; done

sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

sudo usermod -aG docker $USER

```

``` Setup Postgres
mkdir -p /data/postgresql
chown 26:26 /data/postgresql
chmod 700 /data/postgresql

cd /opt/db-kong/percona-postgres
cp .env.example .env
chmod 600 .env
vi .env

sudo docker network create kong-internal
sudo docker network ls

docker compose config
docker compose pull
docker compose up -d
```

# Percona PostgreSQL

Single-node Percona Distribution for PostgreSQL deployment for the production database host.

The cloud platform is responsible for host resilience and external backup, so this stack intentionally does not include Patroni, etcd, HAProxy, or pgBackRest.

## Included

- Percona Distribution for PostgreSQL 18
- pgvector
- pg_stat_monitor
- Persistent host storage
- PostgreSQL health check
- Docker log rotation
- SELinux-aware bind mounts for Oracle Linux

PMM Server is expected to run separately. This PostgreSQL instance is prepared for PMM Query Analytics through `pg_stat_monitor`.

## Files

```text
postgres/
├── README.md
├── docker-compose.yml
├── .env.example
└── initdb/
    └── 01-enable-extensions.sh
```

## Why these extensions are enabled

### pgvector

`pgvector` adds vector types and similarity search to PostgreSQL. It can be used for embeddings, semantic search, RAG, recommendation features, and other vector workloads while keeping normal relational data in PostgreSQL.

The initialization script enables:

```sql
CREATE EXTENSION vector;
```

inside the database configured by `POSTGRES_DB`.

If another database also needs pgvector, enable it separately:

```sql
CREATE EXTENSION vector;
```

### pg_stat_monitor

`pg_stat_monitor` collects detailed PostgreSQL query performance statistics and integrates well with Percona Monitoring and Management.

The container starts PostgreSQL with:

```text
shared_preload_libraries=pg_stat_monitor
pg_stat_monitor.pgsm_query_max_len=2048
pg_stat_monitor.pgsm_normalized_query=1
pg_stat_monitor.pgsm_enable_query_plan=off
```

The initialization script creates `pg_stat_monitor` in the `postgres` database.

## 1. Prepare the data directory

The default host path is:

```text
/data/postgresql
```

Create it before starting the container:

```bash
mkdir -p /data/postgresql
chown 26:26 /data/postgresql
chmod 700 /data/postgresql
```

The Percona PostgreSQL container runs PostgreSQL as UID 26.

If the cloud data disk is mounted elsewhere, change `POSTGRES_DATA_DIR` in `.env`.

## 2. Create the environment file

```bash
cd /opt/db-kong/percona-postgres

cp .env.example .env
chmod 600 .env
vi .env
```

At minimum, change:

```text
POSTGRES_PASSWORD
POSTGRES_DB
```

For remote application access, change `POSTGRES_BIND_IP` from `127.0.0.1` to the host's private/VPC IP and restrict TCP port 5432 using the cloud firewall/security group.

Avoid exposing PostgreSQL directly to the public Internet.

## 3. Validate Compose

```bash
docker compose config
```

Review the rendered configuration before starting the database.

## 4. Start PostgreSQL

```bash
docker compose pull
docker compose up -d
```

Check status:

```bash
docker compose ps
```

Follow logs:

```bash
docker compose logs -f postgres
```

## 5. Verify PostgreSQL

Open psql:

```bash
docker compose exec postgres psql -U postgres
```

Check the server version:

```sql
SELECT version();
```

List databases:

```sql
\l
```

## 6. Verify pg_stat_monitor

From the `postgres` database:

```sql
\c postgres
SELECT pg_stat_monitor_version();
```

You can also check the extension:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'pg_stat_monitor';
```

## 7. Verify pgvector

Connect to the application database:

```sql
\c appdb
```

Replace `appdb` if `POSTGRES_DB` has another value.

Check pgvector:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'vector';
```

Simple vector test:

```sql
CREATE TABLE vector_test (
    id BIGSERIAL PRIMARY KEY,
    embedding VECTOR(3)
);

INSERT INTO vector_test (embedding)
VALUES
    ('[1,2,3]'),
    ('[4,5,6]');

SELECT
    id,
    embedding,
    embedding <-> '[1,2,3]' AS distance
FROM vector_test
ORDER BY embedding <-> '[1,2,3]';
```

Remove the test table afterward:

```sql
DROP TABLE vector_test;
```

## Important: init scripts run once

Files under:

```text
/docker-entrypoint-initdb.d
```

are executed only when PostgreSQL initializes an empty data directory.

If `/data/postgresql` already contains an existing PostgreSQL cluster, changing `initdb/01-enable-extensions.sh` will not run it again.

For an existing database, enable extensions manually with `CREATE EXTENSION`.

Do not delete the production data directory just to rerun an initialization script.

## PMM integration

PMM Server should run on a separate monitoring host.

When PMM Client is installed on this database host, create a dedicated PMM PostgreSQL user:

```sql
CREATE USER pmm
WITH SUPERUSER
ENCRYPTED PASSWORD 'CHANGE_ME_STRONG_PASSWORD';
```

Then register PostgreSQL with PMM using `pg_stat_monitor` as the query source. A typical command is:

```bash
pmm-admin add postgresql   --username=pmm   --password='CHANGE_ME_STRONG_PASSWORD'   --query-source=pgstatmonitor   --service-name=db-kong-postgres
```

If SQL query examples may contain sensitive values, add:

```text
--disable-queryexamples
```

PMM Client and PMM Server configuration should be managed separately from the database password in this repository.

## Common operations

Start:

```bash
docker compose up -d
```

Stop:

```bash
docker compose stop
```

Restart:

```bash
docker compose restart postgres
```

Status:

```bash
docker compose ps
```

Logs:

```bash
docker compose logs -f postgres
```

Open psql:

```bash
docker compose exec postgres psql -U postgres
```

## Updating the container

For an update within the same PostgreSQL major version:

```bash
git pull
docker compose config
docker compose pull
docker compose up -d
```

Then verify:

```bash
docker compose ps
docker compose logs --tail=100 postgres
```

Do not perform a PostgreSQL major version upgrade by only changing the image tag. Major upgrades require a PostgreSQL upgrade procedure such as `pg_upgrade`, logical migration, or another supported migration path.

## Storage and backup responsibility

Current responsibility split:

```text
Cloud platform
├── host / VM resilience
├── storage resilience
└── external backup / snapshot / DR

This Docker stack
├── PostgreSQL
├── pgvector
├── pg_stat_monitor
├── persistent PGDATA
└── PMM-ready query monitoring
```

Cloud disk snapshots should be checked to confirm whether they provide the recovery point objectives required by the application. A VM or disk snapshot is not automatically equivalent to PostgreSQL point-in-time recovery.

## Security notes

- Do not commit `.env`.
- Do not use `POSTGRES_HOST_AUTH_METHOD=trust`.
- Keep PostgreSQL on a private network.
- Restrict TCP/5432 to known application sources.
- Keep the GitLab deploy private key outside this repository.
- Review `git diff` before pushing production changes.
- Keep SELinux enabled. The Compose bind mounts use `:Z` for appropriate relabeling on Oracle Linux.
