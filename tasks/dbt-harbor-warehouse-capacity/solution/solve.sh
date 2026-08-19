#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create schemas using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating schemas using admin role..."
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

# dbt generate_schema_name produces: main_staging, main_intermediate, main_marts
# Also need lowercase "main" for test verifier views
schemas_to_create = ['"main"', 'MAIN_STAGING', 'MAIN_INTERMEDIATE', 'MAIN_MARTS']

try:
    for schema in schemas_to_create:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT SELECT ON ALL VIEWS IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}')
        print(f"Successfully pre-created schema {schema} in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

PROJECT_DIR="/app/dbt_project"

# Create dbt project directory structure
mkdir -p "$PROJECT_DIR/models/staging/capacity"
mkdir -p "$PROJECT_DIR/models/intermediate/capacity"
mkdir -p "$PROJECT_DIR/models/marts/capacity"
mkdir -p "$PROJECT_DIR/macros"

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > "$PROJECT_DIR/profiles.yml" <<PROFILES
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
    cat > "$PROJECT_DIR/profiles.yml" <<PROFILES
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

export DBT_PROFILES_DIR="$PROJECT_DIR"

# Create dbt_project.yml
cat > "$PROJECT_DIR/dbt_project.yml" << 'EOF'
name: warehouse_capacity
version: "1.0"
profile: retail_dw_master

model-paths: ["models"]
macro-paths: ["macros"]

models:
  warehouse_capacity:
    staging:
      +schema: staging
      +materialized: view
    intermediate:
      +schema: intermediate
      +materialized: view
    marts:
      +schema: marts
      +materialized: table
EOF

# Note: We do NOT override generate_schema_name, so dbt will use default behavior
# which creates schemas like main_staging, main_intermediate, main_marts

# For Snowflake: override generate_schema_name to keep models in the expected schemas
# but ensure our custom models go to main_staging, main_intermediate, main_marts
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$PROJECT_DIR/macros/utils"
    cat > "$PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'GENMACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is not none and custom_schema_name | trim != '' -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
GENMACRO
fi

# Create sources definition
cat > "$PROJECT_DIR/models/staging/capacity/_sources.yml" << 'EOF'
version: 2

sources:
  - name: orders
    schema: ORDERS
    tables:
      - name: ORDERS
      - name: SHIPMENTS

  - name: inventory
    schema: INVENTORY
    tables:
      - name: WAREHOUSES
      - name: WAREHOUSE_LOCATIONS
EOF

# =============================================================================
# STAGING MODELS
# =============================================================================

# Model 1: stg_capacity__orders
# EXTRACT(DOW FROM ...) returns 0=Sunday in DuckDB.
# In Snowflake, DAYOFWEEK(date) returns 0=Sunday.
# Use Jinja for cross-DB compatibility.
cat > "$PROJECT_DIR/models/staging/capacity/stg_capacity__orders.sql" << 'EOF'
{{ config(
    materialized='view',
    schema='staging'
) }}

with orders as (
    select
        ORDER_ID as order_id,
        WAREHOUSE_ID as warehouse_id,
        CAST(ORDERED_AT AS TIMESTAMP) as ordered_at,
        CAST(ORDERED_AT AS DATE) as order_date,
        CAST(EXTRACT(HOUR FROM CAST(ORDERED_AT AS TIMESTAMP)) AS INTEGER) as order_hour,
        {% if target.type == 'snowflake' %}
        CAST(DAYOFWEEK(CAST(ORDERED_AT AS DATE)) AS INTEGER) as day_of_week,
        {% else %}
        CAST(EXTRACT(DOW FROM CAST(ORDERED_AT AS TIMESTAMP)) AS INTEGER) as day_of_week,
        {% endif %}
        CAST(COALESCE(GRAND_TOTAL, 0) AS DOUBLE) as grand_total
    from {{ source('orders', 'ORDERS') }}
    where WAREHOUSE_ID is not null
      and ORDERED_AT is not null
)

select * from orders
EOF

# Model 2: stg_capacity__shipments
cat > "$PROJECT_DIR/models/staging/capacity/stg_capacity__shipments.sql" << 'EOF'
{{ config(
    materialized='view',
    schema='staging'
) }}

with shipments as (
    select
        SHIPMENT_ID as shipment_id,
        ORDER_ID as order_id,
        WAREHOUSE_ID as warehouse_id,
        CAST(SHIPPED_AT AS TIMESTAMP) as shipped_at,
        CAST(SHIPPED_AT AS DATE) as shipment_date,
        CAST(EXTRACT(HOUR FROM CAST(SHIPPED_AT AS TIMESTAMP)) AS INTEGER) as shipment_hour,
        STATUS as status
    from {{ source('orders', 'SHIPMENTS') }}
    where SHIPPED_AT is not null
)

select * from shipments
EOF

# =============================================================================
# INTERMEDIATE MODELS
# =============================================================================

# Model 3: int_capacity__hourly_volume
# DuckDB has range(0,24) but Snowflake does not. Use Jinja for cross-DB.
cat > "$PROJECT_DIR/models/intermediate/capacity/int_capacity__hourly_volume.sql" << 'EOF'
{{ config(
    materialized='view',
    schema='intermediate'
) }}

with order_hourly as (
    select
        warehouse_id,
        order_date as volume_date,
        order_hour as volume_hour,
        count(*) as order_count,
        sum(grand_total) as order_value
    from {{ ref('stg_capacity__orders') }}
    group by warehouse_id, order_date, order_hour
),

shipment_hourly as (
    select
        warehouse_id,
        shipment_date as volume_date,
        shipment_hour as volume_hour,
        count(*) as shipment_count
    from {{ ref('stg_capacity__shipments') }}
    group by warehouse_id, shipment_date, shipment_hour
),

warehouse_dates as (
    select distinct warehouse_id, order_date as volume_date
    from {{ ref('stg_capacity__orders') }}
    union
    select distinct warehouse_id, shipment_date as volume_date
    from {{ ref('stg_capacity__shipments') }}
),

{% if target.type == 'snowflake' %}
hours as (
    select ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 as volume_hour
    from TABLE(GENERATOR(ROWCOUNT => 24))
),
{% else %}
hours as (
    select range as volume_hour
    from range(0, 24)
),
{% endif %}

grid as (
    select
        d.warehouse_id,
        d.volume_date,
        h.volume_hour
    from warehouse_dates d
    cross join hours h
),

combined as (
    select
        g.warehouse_id,
        g.volume_date,
        CAST(g.volume_hour AS INTEGER) as volume_hour,
        CAST(coalesce(o.order_count, 0) AS INTEGER) as order_count,
        CAST(coalesce(s.shipment_count, 0) AS INTEGER) as shipment_count,
        CAST(coalesce(o.order_value, 0) AS DOUBLE) as order_value
    from grid g
    left join order_hourly o
        on g.warehouse_id = o.warehouse_id
        and g.volume_date = o.volume_date
        and g.volume_hour = o.volume_hour
    left join shipment_hourly s
        on g.warehouse_id = s.warehouse_id
        and g.volume_date = s.volume_date
        and g.volume_hour = s.volume_hour
)

select * from combined
EOF

# Model 4: int_capacity__daily_utilization
cat > "$PROJECT_DIR/models/intermediate/capacity/int_capacity__daily_utilization.sql" << 'EOF'
{{ config(
    materialized='view',
    schema='intermediate'
) }}

with daily_orders as (
    select
        warehouse_id,
        order_date as utilization_date,
        CAST(count(*) AS INTEGER) as daily_orders,
        CAST(sum(grand_total) AS DOUBLE) as daily_order_value
    from {{ ref('stg_capacity__orders') }}
    group by warehouse_id, order_date
),

daily_shipments as (
    select
        warehouse_id,
        shipment_date as utilization_date,
        CAST(count(*) AS INTEGER) as daily_shipments
    from {{ ref('stg_capacity__shipments') }}
    group by warehouse_id, shipment_date
),

warehouse_locations as (
    select
        WAREHOUSE_ID as warehouse_id,
        CAST(count(*) AS INTEGER) as location_count
    from {{ source('inventory', 'WAREHOUSE_LOCATIONS') }}
    group by WAREHOUSE_ID
),

combined as (
    select
        coalesce(o.warehouse_id, s.warehouse_id) as warehouse_id,
        coalesce(o.utilization_date, s.utilization_date) as utilization_date,
        CAST(coalesce(o.daily_orders, 0) AS INTEGER) as daily_orders,
        CAST(coalesce(s.daily_shipments, 0) AS INTEGER) as daily_shipments,
        CAST(coalesce(o.daily_order_value, 0) AS DOUBLE) as daily_order_value
    from daily_orders o
    full outer join daily_shipments s
        on o.warehouse_id = s.warehouse_id
        and o.utilization_date = s.utilization_date
),

with_capacity as (
    select
        c.warehouse_id,
        c.utilization_date,
        c.daily_orders,
        c.daily_shipments,
        c.daily_order_value,
        CAST(coalesce(wl.location_count, 50) AS INTEGER) as location_count,
        CAST(coalesce(wl.location_count, 50) AS DOUBLE) * 0.05 as theoretical_daily_capacity,
        case
            when coalesce(wl.location_count, 50) * 0.05 > 0
            then CAST(c.daily_orders AS DOUBLE) / (coalesce(wl.location_count, 50) * 0.05)
            else 0
        end as utilization_rate
    from combined c
    left join warehouse_locations wl
        on c.warehouse_id = wl.warehouse_id
)

select * from with_capacity
EOF

# Model 5: int_capacity__peak_periods
cat > "$PROJECT_DIR/models/intermediate/capacity/int_capacity__peak_periods.sql" << 'EOF'
{{ config(
    materialized='view',
    schema='intermediate'
) }}

with hourly_volume as (
    select
        warehouse_id,
        volume_date,
        volume_hour,
        order_count,
        shipment_count
    from {{ ref('int_capacity__hourly_volume') }}
),

with_percentiles as (
    select
        warehouse_id,
        volume_date,
        volume_hour,
        order_count,
        shipment_count,
        CAST(ntile(100) over (
            partition by warehouse_id
            order by order_count
        ) AS INTEGER) as volume_percentile
    from hourly_volume
),

with_peak_flag as (
    select
        warehouse_id,
        volume_date,
        volume_hour,
        order_count,
        shipment_count,
        volume_percentile,
        case when volume_percentile >= 90 then 1 else 0 end as is_peak_hour
    from with_percentiles
)

select * from with_peak_flag
EOF

# =============================================================================
# MART MODELS
# =============================================================================

# Model 6: fct_warehouse_capacity
cat > "$PROJECT_DIR/models/marts/capacity/fct_warehouse_capacity.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='marts'
) }}

with daily_util as (
    select
        warehouse_id,
        utilization_date as capacity_date,
        CAST(daily_orders AS INTEGER) as total_orders,
        CAST(daily_shipments AS INTEGER) as total_shipments,
        CAST(daily_order_value AS DOUBLE) as total_order_value,
        CAST(utilization_rate AS DOUBLE) as utilization_rate
    from {{ ref('int_capacity__daily_utilization') }}
),

peak_stats as (
    select
        warehouse_id,
        volume_date as capacity_date,
        CAST(sum(is_peak_hour) AS INTEGER) as peak_hour_count,
        CAST(avg(order_count) AS DOUBLE) as avg_hourly_orders,
        CAST(max(order_count) AS INTEGER) as max_hourly_orders
    from {{ ref('int_capacity__peak_periods') }}
    group by warehouse_id, volume_date
),

combined as (
    select
        d.warehouse_id,
        d.capacity_date,
        d.total_orders,
        d.total_shipments,
        d.total_order_value,
        d.utilization_rate,
        CAST(coalesce(p.peak_hour_count, 0) AS INTEGER) as peak_hour_count,
        CAST(coalesce(p.avg_hourly_orders, 0) AS DOUBLE) as avg_hourly_orders,
        CAST(coalesce(p.max_hourly_orders, 0) AS INTEGER) as max_hourly_orders,
        case
            when coalesce(p.avg_hourly_orders, 0) > 0
            then CAST(coalesce(p.max_hourly_orders, 0) AS DOUBLE) / p.avg_hourly_orders
            else 1.0
        end as peak_load_factor,
        (1 - d.utilization_rate) * 100 as capacity_headroom_pct,
        CAST(avg(d.total_orders) over (
            partition by d.warehouse_id
            order by d.capacity_date
            rows between 6 preceding and current row
        ) AS DOUBLE) as rolling_7d_avg_orders
    from daily_util d
    left join peak_stats p
        on d.warehouse_id = p.warehouse_id
        and d.capacity_date = p.capacity_date
)

select * from combined
EOF

# Model 7: rpt_capacity_bottlenecks
cat > "$PROJECT_DIR/models/marts/capacity/rpt_capacity_bottlenecks.sql" << 'EOF'
{{ config(
    materialized='table',
    schema='marts'
) }}

with capacity as (
    select
        warehouse_id,
        capacity_date,
        CAST(utilization_rate AS DOUBLE) as utilization_rate,
        CAST(total_orders AS INTEGER) as total_orders,
        CAST(peak_load_factor AS DOUBLE) as peak_load_factor
    from {{ ref('fct_warehouse_capacity') }}
    where utilization_rate >= 0.75
),

with_severity as (
    select
        warehouse_id,
        capacity_date,
        utilization_rate,
        total_orders,
        peak_load_factor,
        case
            when utilization_rate >= 0.95 then 'CRITICAL'
            when utilization_rate >= 0.85 then 'HIGH'
            else 'MODERATE'
        end as bottleneck_severity
    from capacity
)

select *
from with_severity
order by utilization_rate desc, capacity_date desc
EOF

# Run dbt
cd "$PROJECT_DIR"
dbt deps || true
dbt run --profiles-dir . --target dev

# For Snowflake: create lowercase-quoted views so information_schema metadata
# matches lowercase identifiers expected by the test verifier.
if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    cat > "$PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set schemas_and_tables = [
    ('MAIN_STAGING', 'stg_capacity__orders'),
    ('MAIN_STAGING', 'stg_capacity__shipments'),
    ('MAIN_INTERMEDIATE', 'int_capacity__hourly_volume'),
    ('MAIN_INTERMEDIATE', 'int_capacity__daily_utilization'),
    ('MAIN_INTERMEDIATE', 'int_capacity__peak_periods'),
    ('MAIN_MARTS', 'fct_warehouse_capacity'),
    ('MAIN_MARTS', 'rpt_capacity_bottlenecks'),
  ] %}
  {% for src_schema, t in schemas_and_tables %}
    {% set src_table = t | upper %}
    {% set tgt_schema = src_schema | lower %}
    {% set db = target.database %}
    {% set sql %}
      CREATE OR REPLACE VIEW "{{ db }}"."main"."{{ t }}" AS SELECT * FROM {{ db }}.{{ src_schema }}.{{ src_table }}
    {% endset %}
    {% do run_query(sql) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views --profiles-dir . --target dev
fi

echo "All warehouse capacity models created and executed successfully"
