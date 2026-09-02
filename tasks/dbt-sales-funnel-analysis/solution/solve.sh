#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory (standalone project)
DBT_PROJECT_DIR="/app/dbt_project"
echo "Using dbt project: $DBT_PROJECT_DIR"

# Create dbt project structure
mkdir -p $DBT_PROJECT_DIR/models/{staging,intermediate,marts}
mkdir -p $DBT_PROJECT_DIR/macros

# Create dbt_project.yml
cat > $DBT_PROJECT_DIR/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'

model-paths: ["models"]
macro-paths: ["macros"]

models:
  dbt_project:
    staging:
      +materialized: view
      +schema: funnel_analytics
    intermediate:
      +materialized: view
      +schema: funnel_analytics
    marts:
      +materialized: table
      +schema: funnel_analytics
EOF

# Create generate_schema_name macro - return custom schema directly
cat > $DBT_PROJECT_DIR/macros/generate_schema_name.sql << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema | trim }}
    {%- endif -%}
{%- endmacro %}
EOF

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > $DBT_PROJECT_DIR/profiles.yml <<PROFILES
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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > $DBT_PROJECT_DIR/profiles.yml << EOF
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: main
EOF
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

# Pre-create schemas for Snowflake
# Create views in MAIN schema pointing to actual source tables in RAW_GA/DIGITAL
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    python3 << 'PRECREATE_SCHEMAS'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
)

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE']
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ.get('SNOWFLAKE_ROLE', '')

# Create funnel_analytics schema (MAIN already exists from clone)
for schema in ['funnel_analytics']:
    try:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        print(f'Created schema {schema}')
    except Exception as e:
        print(f'Warning creating {schema}: {e}')

# Grant permissions on MAIN schema (already exists from clone)
try:
    cur.execute(f'GRANT USAGE ON SCHEMA {db}.MAIN TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.MAIN TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.MAIN TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.MAIN TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL VIEWS IN SCHEMA {db}.MAIN TO ROLE {agent_role}')
    print('Granted permissions on MAIN schema')
except Exception as e:
    print(f'Warning granting MAIN permissions: {e}')

# Create views in MAIN schema pointing to actual source tables
# SESSIONS -> RAW_GA.SESSIONS, EVENTS -> RAW_GA.EVENTS
view_mappings = {
    'SESSIONS': 'RAW_GA.SESSIONS',
    'EVENTS': 'RAW_GA.EVENTS',
}
for view_name, source_table in view_mappings.items():
    try:
        cur.execute(f'CREATE OR REPLACE VIEW {db}.MAIN.{view_name} AS SELECT * FROM {db}.{source_table}')
        cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.{view_name} TO ROLE {agent_role}')
        print(f'Created view MAIN.{view_name} -> {source_table}')
    except Exception as e:
        print(f'Warning creating view {view_name}: {e}')

# CARTS: try RAW_GA.CARTS first, fallback to DIGITAL.SHOPPING_CARTS
carts_sources = ['RAW_GA.CARTS', 'DIGITAL.SHOPPING_CARTS', 'DIGITAL.CARTS']
carts_created = False
for carts_source in carts_sources:
    try:
        cur.execute(f'CREATE OR REPLACE VIEW {db}.MAIN.CARTS AS SELECT * FROM {db}.{carts_source}')
        cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.CARTS TO ROLE {agent_role}')
        print(f'Created view MAIN.CARTS -> {carts_source}')
        carts_created = True
        break
    except Exception as e:
        print(f'CARTS source {carts_source} not available: {e}')
if not carts_created:
    print('WARNING: Could not create CARTS view from any source')

cur.close()
conn.close()
PRECREATE_SCHEMAS
fi

# Create sources.yml for accessing existing tables
cat > $DBT_PROJECT_DIR/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: SESSIONS
      - name: EVENTS
      - name: CARTS
EOF

# Create staging model for sessions
# Use integer 1/0 instead of true/false for Snowflake compatibility
cat > $DBT_PROJECT_DIR/models/staging/stg_sessions.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(session_id) as session_id,
    trim(visitor_id) as visitor_id,
    trim(customer_id) as customer_id,
    session_start,
    -- Normalize is_converted to integer boolean (handles mixed formats: true/false, Y/N, 1/0)
    case
        when lower(trim(cast(is_converted as varchar))) in ('true', '1', 'y', 'yes') then 1
        else 0
    end as is_converted
from {{ source('main', 'SESSIONS') }}
EOF

# Create staging model for events
cat > $DBT_PROJECT_DIR/models/staging/stg_events.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(event_id) as event_id,
    trim(session_id) as session_id,
    trim(event_type) as event_type,
    event_timestamp
from {{ source('main', 'EVENTS') }}
where event_type in ('view_product', 'add_to_cart')
EOF

# Create staging model for carts
cat > $DBT_PROJECT_DIR/models/staging/stg_carts.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(cart_id) as cart_id,
    trim(session_id) as session_id,
    trim(customer_id) as customer_id,
    trim(status) as status,
    created_at,
    updated_at
from {{ source('main', 'CARTS') }}
EOF

# Create intermediate session funnel model
# Use integer 1/0 for boolean columns for Snowflake compatibility
cat > $DBT_PROJECT_DIR/models/intermediate/int_session_funnel.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

/*
    Session Funnel - Track funnel stages for each session.
    Stages: VIEW -> CART -> PURCHASE
*/

with sessions as (
    select * from {{ ref('stg_sessions') }}
),

events as (
    select * from {{ ref('stg_events') }}
),

carts_converted as (
    select distinct session_id
    from {{ ref('stg_carts') }}
    where status = 'CONVERTED'
),

-- Aggregate events per session
session_events as (
    select
        session_id,
        max(case when event_type = 'view_product' then 1 else 0 end) as has_product_view,
        max(case when event_type = 'add_to_cart' then 1 else 0 end) as has_add_to_cart
    from events
    group by session_id
),

-- Join sessions with events and carts
session_funnel as (
    select
        s.session_id,
        s.visitor_id,
        s.customer_id,
        s.session_start,
        coalesce(e.has_product_view, 0) as has_product_view,
        coalesce(e.has_add_to_cart, 0) as has_add_to_cart,
        -- Purchase: is_converted OR has converted cart
        case when s.is_converted = 1 or c.session_id is not null then 1 else 0 end as has_purchase
    from sessions s
    left join session_events e on s.session_id = e.session_id
    left join carts_converted c on s.session_id = c.session_id
)

select
    session_id,
    visitor_id,
    customer_id,
    session_start,
    has_product_view,
    has_add_to_cart,
    has_purchase,
    -- Determine highest funnel stage reached
    case
        when has_purchase = 1 then 'PURCHASE'
        when has_add_to_cart = 1 then 'CART'
        when has_product_view = 1 then 'VIEW'
        else 'NONE'
    end as funnel_stage
from session_funnel
EOF

# Create funnel conversion rates model
cat > $DBT_PROJECT_DIR/models/marts/funnel_conversion_rates.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Funnel Conversion Rates - Aggregate conversion metrics.
*/

with funnel_data as (
    select
        count(*) as total_sessions,
        sum(case when has_product_view = 1 then 1 else 0 end) as sessions_with_view,
        sum(case when has_add_to_cart = 1 then 1 else 0 end) as sessions_with_cart,
        sum(case when has_purchase = 1 then 1 else 0 end) as sessions_with_purchase
    from {{ ref('int_session_funnel') }}
)

select
    total_sessions,
    sessions_with_view,
    sessions_with_cart,
    sessions_with_purchase,
    -- View rate: sessions with view / total sessions
    case
        when total_sessions > 0
        then round(cast(sessions_with_view as decimal(18,8)) / total_sessions, 4)
        else 0.0
    end as view_rate,
    -- View to cart rate: sessions with cart / sessions with view
    case
        when sessions_with_view > 0
        then round(cast(sessions_with_cart as decimal(18,8)) / sessions_with_view, 4)
        else 0.0
    end as view_to_cart_rate,
    -- Cart to purchase rate: sessions with purchase / sessions with cart
    case
        when sessions_with_cart > 0
        then round(cast(sessions_with_purchase as decimal(18,8)) / sessions_with_cart, 4)
        else 0.0
    end as cart_to_purchase_rate,
    -- Overall conversion rate: sessions with purchase / total sessions
    case
        when total_sessions > 0
        then round(cast(sessions_with_purchase as decimal(18,8)) / total_sessions, 4)
        else 0.0
    end as overall_conversion_rate
from funnel_data
EOF

# Create funnel dropoff analysis model
# Use integer comparison (= 0) instead of NOT boolean for Snowflake compatibility
cat > $DBT_PROJECT_DIR/models/marts/funnel_dropoff_analysis.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Funnel Dropoff Analysis - Identify where users drop off.

    Drop-off stages:
    - BEFORE_VIEW: Sessions with no product views
    - VIEW_TO_CART: Sessions with view but no cart add
    - CART_TO_PURCHASE: Sessions with cart add but no purchase
*/

with session_data as (
    select
        session_id,
        has_product_view,
        has_add_to_cart,
        has_purchase
    from {{ ref('int_session_funnel') }}
),

totals as (
    select count(*) as total_sessions from session_data
),

dropoffs as (
    -- BEFORE_VIEW: No product views at all
    select
        'BEFORE_VIEW' as dropoff_stage,
        count(*) as session_count
    from session_data
    where has_product_view = 0

    union all

    -- VIEW_TO_CART: Had view but no cart add
    select
        'VIEW_TO_CART' as dropoff_stage,
        count(*) as session_count
    from session_data
    where has_product_view = 1 and has_add_to_cart = 0

    union all

    -- CART_TO_PURCHASE: Had cart add but no purchase
    select
        'CART_TO_PURCHASE' as dropoff_stage,
        count(*) as session_count
    from session_data
    where has_add_to_cart = 1 and has_purchase = 0
)

select
    d.dropoff_stage,
    d.session_count,
    case
        when t.total_sessions > 0
        then round(cast(d.session_count as decimal(18,8)) / t.total_sessions, 4)
        else 0.0
    end as dropoff_rate
from dropoffs d
cross join totals t
order by
    case d.dropoff_stage
        when 'BEFORE_VIEW' then 1
        when 'VIEW_TO_CART' then 2
        when 'CART_TO_PURCHASE' then 3
    end
EOF

# Run dbt
cd $DBT_PROJECT_DIR
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt deps || true
dbt run --profiles-dir .

echo "Solution complete!"
