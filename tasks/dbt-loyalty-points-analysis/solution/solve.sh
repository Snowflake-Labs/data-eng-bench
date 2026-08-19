#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create loyalty_analytics schema using admin role (agent role lacks CREATE SCHEMA)
DB_TYPE="${DB_TYPE:-duckdb}"
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating loyalty_analytics schema using admin role..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    for schema_name in ['LOYALTY_ANALYTICS', '"loyalty_analytics"']:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema_name}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema_name} TO ROLE {agent_role}')
    print(f"Successfully pre-created loyalty_analytics schema in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi

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
      schema: loyalty_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
    echo "Using dbt project directory: $DBT_PROJECT_DIR"

    # DuckDB profile (uses pre-built base project profile name)
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" << PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: loyalty_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# ============================================================
# CREATE MODELS
# ============================================================

if [ "$DB_TYPE" = "snowflake" ]; then
    # ============================================================
    # SNOWFLAKE: Use unique staging model names to avoid conflicts
    # with existing base project models. Use base project source names.
    # Do NOT create a separate sources.yml -- base project already has _sources.yml.
    # ============================================================

    mkdir -p "$DBT_PROJECT_DIR/models/staging/loyalty_task"
    mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
    mkdir -p "$DBT_PROJECT_DIR/models/marts"

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/stg_lp_transactions.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(TRANSACTION_ID) as transaction_id,
    trim(CUSTOMER_ID) as customer_id,
    trim(PROGRAM_ID) as program_id,
    trim(TRANSACTION_TYPE) as transaction_type,
    POINTS as points,
    BALANCE_AFTER as balance_after,
    trim(ORDER_ID) as order_id,
    trim(DESCRIPTION) as description,
    EXPIRES_AT as expires_at,
    CREATED_AT as created_at
from {{ source('marketing', 'LOYALTY_POINTS_TRANSACTIONS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/stg_lp_programs.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(PROGRAM_ID) as program_id,
    trim(PROGRAM_NAME) as program_name,
    trim(PROGRAM_TYPE) as program_type,
    POINTS_PER_DOLLAR as points_per_dollar,
    POINTS_VALUE as points_value,
    IS_ACTIVE as is_active
from {{ source('marketing', 'LOYALTY_PROGRAMS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/stg_lp_customers.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(CUSTOMER_ID) as customer_id,
    trim(FIRST_NAME) as first_name,
    trim(LAST_NAME) as last_name,
    trim(EMAIL) as email,
    trim(STATUS) as status
from {{ source('customer', 'CUSTOMERS') }}
EOF

    # Intermediate model
    cat > "$DBT_PROJECT_DIR/models/intermediate/int_loyalty_metrics.sql" << 'EOF'
{{ config(materialized='view') }}

select
    program_id,
    count(distinct customer_id) as member_count,
    sum(case when transaction_type in ('EARN', 'BONUS') then points else 0 end) as points_earned,
    sum(case when transaction_type = 'REDEEM' then abs(points) else 0 end) as points_redeemed,
    sum(case when transaction_type = 'EXPIRE' then abs(points) else 0 end) as points_expired
from {{ ref('stg_lp_transactions') }}
group by program_id
EOF

    # Final mart model
    cat > "$DBT_PROJECT_DIR/models/marts/program_loyalty_summary.sql" << 'EOF'
{{ config(materialized='table') }}

select
    m.program_id,
    p.program_name,
    m.member_count,
    m.points_earned,
    m.points_redeemed,
    m.points_expired,
    m.points_earned - m.points_redeemed - m.points_expired as points_balance,
    round(100.0 * m.points_redeemed / nullif(m.points_earned, 0), 2) as redemption_rate,
    cast(round((m.points_earned - m.points_redeemed - m.points_expired) * 1.0 / nullif(m.member_count, 0)) as integer) as avg_points_per_member
from {{ ref('int_loyalty_metrics') }} m
inner join {{ ref('stg_lp_programs') }} p on m.program_id = p.program_id
order by m.points_earned desc
EOF

else
    # ============================================================
    # DUCKDB: Add models to pre-built base project
    # ============================================================

    mkdir -p "$DBT_PROJECT_DIR/models/staging/loyalty_task"
    mkdir -p "$DBT_PROJECT_DIR/models/intermediate"
    mkdir -p "$DBT_PROJECT_DIR/models/marts"

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/sources.yml" << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: LOYALTY_POINTS_TRANSACTIONS
      - name: LOYALTY_PROGRAMS
      - name: CUSTOMERS
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/stg_lp_transactions.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(TRANSACTION_ID) as transaction_id,
    trim(CUSTOMER_ID) as customer_id,
    trim(PROGRAM_ID) as program_id,
    trim(TRANSACTION_TYPE) as transaction_type,
    POINTS as points,
    BALANCE_AFTER as balance_after,
    trim(ORDER_ID) as order_id,
    trim(DESCRIPTION) as description,
    EXPIRES_AT as expires_at,
    CREATED_AT as created_at
from {{ source('main', 'LOYALTY_POINTS_TRANSACTIONS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/stg_lp_programs.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(PROGRAM_ID) as program_id,
    trim(PROGRAM_NAME) as program_name,
    trim(PROGRAM_TYPE) as program_type,
    POINTS_PER_DOLLAR as points_per_dollar,
    POINTS_VALUE as points_value,
    IS_ACTIVE as is_active
from {{ source('main', 'LOYALTY_PROGRAMS') }}
EOF

    cat > "$DBT_PROJECT_DIR/models/staging/loyalty_task/stg_lp_customers.sql" << 'EOF'
{{ config(materialized='view') }}

select
    trim(CUSTOMER_ID) as customer_id,
    trim(FIRST_NAME) as first_name,
    trim(LAST_NAME) as last_name,
    trim(EMAIL) as email,
    trim(STATUS) as status
from {{ source('main', 'CUSTOMERS') }}
EOF

    # Intermediate model
    cat > "$DBT_PROJECT_DIR/models/intermediate/int_loyalty_metrics.sql" << 'EOF'
{{ config(materialized='view') }}

select
    program_id,
    count(distinct customer_id) as member_count,
    sum(case when transaction_type in ('EARN', 'BONUS') then points else 0 end) as points_earned,
    sum(case when transaction_type = 'REDEEM' then abs(points) else 0 end) as points_redeemed,
    sum(case when transaction_type = 'EXPIRE' then abs(points) else 0 end) as points_expired
from {{ ref('stg_lp_transactions') }}
group by program_id
EOF

    # Final mart model
    cat > "$DBT_PROJECT_DIR/models/marts/program_loyalty_summary.sql" << 'EOF'
{{ config(materialized='table') }}

select
    m.program_id,
    p.program_name,
    m.member_count,
    m.points_earned,
    m.points_redeemed,
    m.points_expired,
    m.points_earned - m.points_redeemed - m.points_expired as points_balance,
    round(100.0 * m.points_redeemed / nullif(m.points_earned, 0), 2) as redemption_rate,
    cast(round((m.points_earned - m.points_redeemed - m.points_expired) * 1.0 / nullif(m.member_count, 0)) as integer) as avg_points_per_member
from {{ ref('int_loyalty_metrics') }} m
inner join {{ ref('stg_lp_programs') }} p on m.program_id = p.program_id
order by m.points_earned desc
EOF

fi

# ============================================================
# RUN DBT
# ============================================================

cd "$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps || true

echo "Running dbt models..."
if [ "$DB_TYPE" = "snowflake" ]; then
    dbt run --select stg_lp_transactions stg_lp_programs stg_lp_customers int_loyalty_metrics program_loyalty_summary
else
    dbt run --select stg_lp_transactions stg_lp_programs stg_lp_customers int_loyalty_metrics program_loyalty_summary
fi

echo "DBT run completed successfully!"
