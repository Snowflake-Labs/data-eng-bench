#!/bin/bash
# Solution script for dbt customer risk scoring task
set -e

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
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

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
      schema: main
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project
else
    DBT_PROJECT_DIR="/app/dbt_project"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # Create new dbt project
    mkdir -p "$DBT_PROJECT_DIR"
    cd "$DBT_PROJECT_DIR"

    cat > dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2

profile: 'dbt_project'

model-paths: ["models"]

models:
  dbt_project:
    staging:
      +materialized: view
    marts:
      +materialized: table
EOF

    # DuckDB profile (write to project dir so DBT_PROFILES_DIR works)
    cat > "$DBT_PROJECT_DIR/profiles.yml" << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: risk_analytics
EOF
    # Also write to ~/.dbt for fallback
    mkdir -p ~/.dbt
    cp "$DBT_PROJECT_DIR/profiles.yml" ~/.dbt/profiles.yml
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create directory structure
mkdir -p "$DBT_PROJECT_DIR/models/staging"
mkdir -p "$DBT_PROJECT_DIR/models/marts"

if [ "$DB_TYPE" = "snowflake" ]; then
    # ============================================================
    # SNOWFLAKE: Overwrite existing staging models at their subdirectory paths
    # to avoid duplicate model name conflicts. Use base project source names.
    # Do NOT create a separate sources.yml -- base project already has _sources.yml.
    # ============================================================

    cat > "$DBT_PROJECT_DIR/models/staging/stg_orders_risk.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    trim(status) as status,
    trim(payment_status) as payment_status,
    chargeback_flag,
    ordered_at
from {{ source('orders', 'ORDERS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_customers_risk.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(customer_id) as customer_id,
    trim(first_name) as first_name,
    trim(last_name) as last_name
from {{ source('customer', 'CUSTOMERS') }}
EOF

else
    # ============================================================
    # DUCKDB: Create staging models and sources from scratch
    # ============================================================

    cat > "$DBT_PROJECT_DIR/models/staging/sources.yml" << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: orders
      - name: customers
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_orders_risk.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    trim(status) as status,
    trim(payment_status) as payment_status,
    chargeback_flag,
    ordered_at
from {{ source('main', 'orders') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/stg_customers_risk.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(customer_id) as customer_id,
    trim(first_name) as first_name,
    trim(last_name) as last_name
from {{ source('main', 'customers') }}
EOF

fi

# ============================================================
# MART MODEL - customer_risk_scores
# Uses UPPER(CAST(chargeback_flag AS VARCHAR)) for Snowflake boolean compatibility
# ============================================================

cat > "$DBT_PROJECT_DIR/models/marts/customer_risk_scores.sql" << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with customers as (
    select * from {{ ref('stg_customers_risk') }}
),

orders as (
    select * from {{ ref('stg_orders_risk') }}
),

risk_factors as (
    select
        c.customer_id,
        coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '') as customer_name,
        -- Late payments: orders where payment_status = 'UNPAID'
        coalesce(sum(case when upper(o.payment_status) = 'UNPAID' then 1 else 0 end), 0) as late_payment_count,
        -- Returns: orders with status = 'RETURNED'
        coalesce(sum(case when upper(o.status) = 'RETURNED' then 1 else 0 end), 0) as return_count,
        -- Chargebacks: orders where chargeback_flag = TRUE (VARCHAR-safe)
        coalesce(sum(case when upper(cast(o.chargeback_flag as varchar)) in ('TRUE', '1', 'T', 'Y', 'YES') then 1 else 0 end), 0) as chargeback_count
    from customers c
    left join orders o on c.customer_id = o.customer_id
    group by c.customer_id, c.first_name, c.last_name
),

scored as (
    select
        customer_id,
        customer_name,
        late_payment_count,
        return_count,
        chargeback_count,
        (late_payment_count * 10) + (return_count * 5) + (chargeback_count * 20) as risk_score
    from risk_factors
),

final as (
    select
        customer_id,
        customer_name,
        late_payment_count,
        return_count,
        chargeback_count,
        risk_score,
        case
            when risk_score < 20 then 'LOW'
            when risk_score >= 20 and risk_score < 50 then 'MEDIUM'
            when risk_score >= 50 and risk_score < 100 then 'HIGH'
            else 'CRITICAL'
        end as risk_tier
    from scored
)

select * from final
order by customer_id
EOF

# ============================================================
# RUN DBT
# ============================================================

cd "$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps || true

echo "Running dbt models..."
if [ "$DB_TYPE" = "snowflake" ]; then
    dbt run --select stg_orders_risk stg_customers_risk customer_risk_scores
else
    dbt run
fi

echo "Solution complete!"
