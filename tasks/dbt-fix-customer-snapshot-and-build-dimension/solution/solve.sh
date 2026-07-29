#!/bin/bash
set -e

echo "=========================================="
echo "Applying Fix for Customer Snapshot Bugs"
echo "and Creating dim_customer_current Model"
echo "=========================================="

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi
echo "Using dbt project: $DBT_PROJECT_DIR"

# The bugs in customer_snapshot.sql:
# 1. strategy='timestamp' but changes don't update 'updated_at' timestamp
#    Fix: switch to 'check' strategy to track specific column changes
# 2. WHERE acquisition_source IS NOT NULL silently drops customers
#    Fix: remove the WHERE clause to include all customers

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile - uses private key authentication
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"
else
    # DuckDB profile (default)
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# For Snowflake: create the 'snapshots' schema and grant permissions
# The agent role cannot CREATE SCHEMA, so we use the admin role to do it
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating 'snapshots' schema in Snowflake clone..."
    python3 << 'SCHEMA_SCRIPT'
import snowflake.connector
import os
import base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

def get_private_key():
    private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
    private_key_pem = base64.b64decode(private_key_b64)
    passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    passphrase_bytes = passphrase.encode() if passphrase else None
    p_key = serialization.load_pem_private_key(
        private_key_pem, password=passphrase_bytes, backend=default_backend()
    )
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )

# Connect using admin role to create schema
admin_role = os.environ.get('SNOWFLAKE_ADMIN_ROLE', '')
agent_role = os.environ.get('SNOWFLAKE_AGENT_ROLE', os.environ.get('SNOWFLAKE_ROLE', ''))
clone_db = os.environ['SNOWFLAKE_DATABASE']

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=get_private_key(),
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=admin_role if admin_role else None,
    database=clone_db,
)
cursor = conn.cursor()

# Create snapshots schema
cursor.execute(f"CREATE SCHEMA IF NOT EXISTS {clone_db}.snapshots")
print(f"Created schema: {clone_db}.snapshots")

# Grant permissions on the new schema to agent role
if agent_role:
    # Grant CREATE SCHEMA so dbt can run CREATE SCHEMA IF NOT EXISTS without errors
    cursor.execute(f"GRANT CREATE SCHEMA ON DATABASE {clone_db} TO ROLE {agent_role}")
    cursor.execute(f"GRANT USAGE ON SCHEMA {clone_db}.snapshots TO ROLE {agent_role}")
    cursor.execute(f"GRANT CREATE TABLE ON SCHEMA {clone_db}.snapshots TO ROLE {agent_role}")
    cursor.execute(f"GRANT CREATE VIEW ON SCHEMA {clone_db}.snapshots TO ROLE {agent_role}")
    cursor.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {clone_db}.snapshots TO ROLE {agent_role}")
    cursor.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {clone_db}.snapshots TO ROLE {agent_role}")
    # Grant future privileges so snapshot table created by dbt is accessible
    cursor.execute(f"GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA {clone_db}.snapshots TO ROLE {agent_role}")
    print(f"Granted permissions on {clone_db}.snapshots to {agent_role}")

conn.close()
print("Schema setup complete")
SCHEMA_SCRIPT
    echo "Snowflake snapshots schema ready"
fi

# ====================================================================
# FIX 1: Repair the customer_snapshot.sql
# ====================================================================

SNAPSHOT_PATH="$DBT_PROJECT_DIR/snapshots/customer_snapshot.sql"

echo "Creating fixed customer_snapshot.sql..."

# The fixes:
# 1. Switch to 'check' strategy to track specific column changes
# 2. Add check_cols to monitor email, customer_type, phone_primary, names, etc.
# 3. Remove WHERE clause that filtered out customers with NULL acquisition_source

mkdir -p "$(dirname "$SNAPSHOT_PATH")"

cat > "$SNAPSHOT_PATH" <<'EOF'
{% snapshot customer_snapshot %}

{{
    config(
      target_schema='snapshots',
      unique_key='customer_id',
      strategy='check',
      check_cols=['email', 'customer_type', 'phone_primary', 'first_name', 'last_name', 'company_name'],
      invalidate_hard_deletes=True
    )
}}

/*
================================================================================
 customer_snapshot - Customer SCD Type 2 Tracking

 FIXED: Using check strategy to track specific column changes
        Removed WHERE filter that excluded customers with NULL acquisition_source
================================================================================
*/

select
    customer_id,
    customer_number,
    customer_type,
    email,
    email_verified,
    phone_primary,
    phone_verified,
    first_name,
    last_name,
    company_name,
    acquisition_source,
    acquisition_campaign,
    current_timestamp as updated_at
from {{ ref('stg_customers') }}

{% endsnapshot %}
EOF

echo ""
echo "Snapshot fix applied successfully!"

# ====================================================================
# FIX 2: Create the dim_customer_current model
# ====================================================================

echo "Creating dim_customer_current model..."

MODELS_DIR="$DBT_PROJECT_DIR/models"
mkdir -p "$MODELS_DIR"

cat > "$MODELS_DIR/dim_customer_current.sql" <<'DIMEOF'
/*
================================================================================
 dim_customer_current - Current Customer Dimension with Analytical Attributes

 Reads from the customer_snapshot (SCD Type 2) and produces a single row per
 customer containing the current record plus derived analytical columns:
   - days_since_last_update: days between dbt_valid_from and today
   - total_versions: count of all snapshot versions for the customer
   - is_recently_changed: true if customer record changed within last 30 days
================================================================================
*/

with current_records as (
    select *
    from {{ ref('customer_snapshot') }}
    where dbt_valid_to is null
),

version_counts as (
    select
        customer_id,
        count(*) as total_versions
    from {{ ref('customer_snapshot') }}
    group by customer_id
)

select
    cr.customer_id,
    cr.customer_number,
    cr.customer_type,
    cr.email,
    cr.email_verified,
    cr.phone_primary,
    cr.phone_verified,
    cr.first_name,
    cr.last_name,
    cr.company_name,
    cr.acquisition_source,
    cr.acquisition_campaign,
    cr.updated_at,
    cr.dbt_scd_id,
    cr.dbt_updated_at,
    cr.dbt_valid_from,
    cr.dbt_valid_to,

    -- days_since_last_update: days from dbt_valid_from to current_date
    {{ datediff("cr.dbt_valid_from", "current_date", "day") }} as days_since_last_update,

    -- total_versions: count of all snapshot rows for this customer
    vc.total_versions,

    -- is_recently_changed: true if dbt_valid_from is within last 30 days
    case
        when {{ datediff("cr.dbt_valid_from", "current_date", "day") }} <= 30
        then true
        else false
    end as is_recently_changed

from current_records cr
inner join version_counts vc
    on cr.customer_id = vc.customer_id
DIMEOF

echo "dim_customer_current model created!"

# ====================================================================
# Build everything
# ====================================================================

echo ""
echo "Building models with fixed snapshot..."
cd "$DBT_PROJECT_DIR"

# Install dbt dependencies
echo "Installing dbt dependencies..."
dbt deps --profiles-dir . > /dev/null 2>&1 || true

# Build required staging models
echo "Building staging models..."
dbt run --select stg_customers --profiles-dir . > /dev/null 2>&1

# Run snapshot to create/update the snapshot table
# IMPORTANT: Only run customer_snapshot -- other snapshots in the project may have
# pre-existing errors (e.g., snap_customers references non-existent updated_at column)
echo "Running snapshot..."
dbt snapshot --select customer_snapshot --profiles-dir .

# Run the dim_customer_current model
echo "Building dim_customer_current model..."
dbt run --select dim_customer_current --profiles-dir .

echo ""
echo "All done! Snapshot fixed and dim_customer_current created."
echo ""
