#!/bin/bash
set -euo pipefail

# Railway supplies independent secrets and private-network database references.
for name in ROUTER__MASTER_DATABASE__HOST ROUTER__MASTER_DATABASE__PORT \
    ROUTER__MASTER_DATABASE__USERNAME ROUTER__MASTER_DATABASE__PASSWORD \
    ROUTER__MASTER_DATABASE__DBNAME ROUTER__REDIS__HOST \
    ROUTER__SECRETS__ADMIN_API_KEY ROUTER__SECRETS__JWT_SECRET \
    ROUTER__SECRETS__MASTER_ENC_KEY ROUTER__API_KEYS__HASH_KEY; do
    if [ -z "${!name:-}" ]; then
        echo "Missing required environment variable: $name" >&2
        exit 1
    fi
done
if [[ ! "$ROUTER__SECRETS__MASTER_ENC_KEY" =~ ^[[:xdigit:]]{64}$ ]] || \
   [[ ! "$ROUTER__API_KEYS__HASH_KEY" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "Master encryption and API-key hashing keys must each contain 64 hex characters." >&2
    exit 1
fi

export PGHOST="$ROUTER__MASTER_DATABASE__HOST"
export PGPORT="$ROUTER__MASTER_DATABASE__PORT"
export PGUSER="$ROUTER__MASTER_DATABASE__USERNAME"
export PGPASSWORD="$ROUTER__MASTER_DATABASE__PASSWORD"
export PGDATABASE="$ROUTER__MASTER_DATABASE__DBNAME"
export PGCONNECT_TIMEOUT=5

# A newly provisioned database or private DNS can become ready after the router.
echo "Waiting for authenticated Postgres connectivity..."
deadline=$((SECONDS + 300))
until psql -X -v ON_ERROR_STOP=1 -tAc 'SELECT 1' >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
        echo "Postgres did not become ready within 300 seconds." >&2
        exit 1
    fi
    sleep 2
done

migrations_dir=/local/migrations
if [ ! -d "$migrations_dir" ]; then
    echo "Missing migration directory: $migrations_dir" >&2
    exit 1
fi
sql_file=$(mktemp)
trap 'rm -f "$sql_file"' EXIT

# Keep one connection and a session-level lock for the entire migration run.
# Preserve the existing Railway migration ledger on upgrades/redeployments.
cat > "$sql_file" <<'SQL'
SELECT pg_advisory_lock(hashtext('railway_hyperswitch_migrations'));
CREATE TABLE IF NOT EXISTS __schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SQL
export LC_ALL=C
for migration_path in "$migrations_dir"/*/; do
    [ -f "${migration_path}up.sql" ] || continue
    version=$(basename "$migration_path")
    if [[ ! "$version" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo "Invalid migration directory name." >&2
        exit 1
    fi
    {
        printf "\\set migration_version '%s'\n" "$version"
        printf "SELECT EXISTS (SELECT 1 FROM __schema_migrations WHERE version = :'migration_version') AS applied \\gset\n"
        printf '\\if :applied\n\\else\n\\echo Applying %s\n' "$version"
        # Upstream concurrent-index migrations explicitly opt out of transactions.
        if ! grep -Eq '^run_in_transaction[[:space:]]*=[[:space:]]*false' "${migration_path}metadata.toml" 2>/dev/null; then
            printf 'BEGIN;\n'
        fi
        printf '\\i %sup.sql\n' "$migration_path"
        printf "INSERT INTO __schema_migrations (version) VALUES (:'migration_version');\n"
        if ! grep -Eq '^run_in_transaction[[:space:]]*=[[:space:]]*false' "${migration_path}metadata.toml" 2>/dev/null; then
            printf 'COMMIT;\n'
        fi
        printf '\\endif\n'
    } >> "$sql_file"
done
psql -X -v ON_ERROR_STOP=1 -f "$sql_file" >/dev/null
echo "Migrations up to date."

echo "Waiting for Redis connectivity..."
deadline=$((SECONDS + 300))
until timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ROUTER__REDIS__HOST" "${ROUTER__REDIS__PORT:-6379}" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
        echo "Redis did not become ready within 300 seconds." >&2
        exit 1
    fi
    sleep 2
done

rm -f "$sql_file"
trap - EXIT
echo "Starting Hyperswitch router."
# Upstream standalone router returns exit code 1 ("I/O: Server shut down")
# after its graceful SIGTERM path. Keep intentional stops successful while
# preserving unexpected crashes and forced kills as failures.
stop_requested=0
router_pid=
forward_shutdown() {
    stop_requested=1
    if [ -n "$router_pid" ]; then
        kill -TERM "$router_pid" 2>/dev/null || true
    fi
}
trap forward_shutdown TERM INT
/local/bin/router -f /local/config/docker_compose.toml &
router_pid=$!
set +e
wait "$router_pid"
router_status=$?
if (( stop_requested )); then
    # The first wait can be interrupted by the trap before the child exits.
    wait "$router_pid"
    final_status=$?
    if (( final_status != 127 )); then
        router_status=$final_status
    fi
    if (( router_status == 0 || router_status == 1 || router_status == 143 || router_status == 130 )); then
        echo "Hyperswitch router stopped by request."
        exit 0
    fi
fi
exit "$router_status"
