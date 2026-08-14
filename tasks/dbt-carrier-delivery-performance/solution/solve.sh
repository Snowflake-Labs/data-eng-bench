#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
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
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

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

if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$DBT_PROJECT_DIR/macros/utils"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'SCHEMAEOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
SCHEMAEOF
fi

cd "$DBT_PROJECT_DIR"

# Create fixed model
mkdir -p models/marts/sales

cat > models/marts/sales/rpt_carrier_performance.sql << 'EOF'
-- Fixed Carrier Performance Model with Peer Metrics
-- Uses conditional Jinja for cross-database compatibility
{{ config(materialized=('table' if target.type == 'snowflake' else 'view')) }}

WITH carrier_primary_method AS (
    SELECT carrier_id, shipping_method_id
    FROM (
        SELECT
            carrier_id,
            shipping_method_id,
            ROW_NUMBER() OVER (PARTITION BY carrier_id ORDER BY COUNT(*) DESC) as rn
        FROM main.stg_orders__shipments
        WHERE carrier_id IS NOT NULL
        GROUP BY carrier_id, shipping_method_id
    ) ranked
    WHERE rn = 1
),

shipment_metrics AS (
    SELECT
        s.carrier_id,
        cpm.shipping_method_id,
        COUNT(*) as total_shipments,
        COUNT(CASE WHEN status = 'DELIVERED' THEN 1 END) as delivered_shipments,
        COUNT(CASE WHEN status = 'IN_TRANSIT' THEN 1 END) as in_transit_shipments,
        COUNT(CASE WHEN status = 'CANCELLED' THEN 1 END) as cancelled_shipments,
        SUM(SHIPPING_COST) as total_shipping_cost,
        SUM(SHIPPING_COST) / NULLIF(COUNT(*), 0) as avg_shipping_cost,
        SUM(WEIGHT) as total_weight,
        SUM(WEIGHT) / NULLIF(COUNT(*), 0) as avg_weight,
        AVG({% if target.type == 'duckdb' %}date_diff('day', SHIPPED_AT, DELIVERED_AT){% else %}DATEDIFF(day, SHIPPED_AT, DELIVERED_AT){% endif %}) as avg_delivery_days,
        MIN({% if target.type == 'duckdb' %}date_diff('day', SHIPPED_AT, DELIVERED_AT){% else %}DATEDIFF(day, SHIPPED_AT, DELIVERED_AT){% endif %}) as min_delivery_days,
        MAX({% if target.type == 'duckdb' %}date_diff('day', SHIPPED_AT, DELIVERED_AT){% else %}DATEDIFF(day, SHIPPED_AT, DELIVERED_AT){% endif %}) as max_delivery_days,
        COUNT(CASE
            WHEN status = 'DELIVERED'
            AND {% if target.type == 'duckdb' %}date_diff('day', SHIPPED_AT, DELIVERED_AT){% else %}DATEDIFF(day, SHIPPED_AT, DELIVERED_AT){% endif %} <= 7
            THEN 1
        END) as on_time_shipments
    FROM main.stg_orders__shipments s
    LEFT JOIN carrier_primary_method cpm ON s.carrier_id = cpm.carrier_id
    WHERE s.carrier_id IS NOT NULL
    GROUP BY s.carrier_id, cpm.shipping_method_id
),

-- Percentile calculations for tier classification (slow = low percentile)
delivery_percentiles AS (
    SELECT
        carrier_id,
        avg_delivery_days,
        PERCENT_RANK() OVER (ORDER BY avg_delivery_days DESC) as slow_percentile
    FROM shipment_metrics
    WHERE avg_delivery_days IS NOT NULL
),

metrics_with_rates AS (
    SELECT
        sm.carrier_id,
        sm.shipping_method_id,
        sm.total_shipments,
        sm.delivered_shipments,
        sm.in_transit_shipments,
        sm.cancelled_shipments,
        sm.total_shipping_cost,
        sm.avg_shipping_cost,
        sm.total_weight,
        sm.avg_weight,
        sm.avg_delivery_days,
        sm.min_delivery_days,
        sm.max_delivery_days,
        sm.on_time_shipments,
        sm.on_time_shipments * 1.0 / NULLIF(sm.delivered_shipments, 0) as on_time_delivery_rate,
        sm.delivered_shipments * 1.0 / NULLIF(sm.total_shipments, 0) as delivery_completion_rate,
        COALESCE(dp.slow_percentile, 0.5) as slow_pct
    FROM shipment_metrics sm
    LEFT JOIN delivery_percentiles dp ON sm.carrier_id = dp.carrier_id
),

-- Global percentiles (faster = higher, cheaper = higher)
-- Use DESC so lower values (faster/cheaper) get higher percentile
global_percentiles AS (
    SELECT
        carrier_id,
        PERCENT_RANK() OVER (ORDER BY avg_delivery_days DESC) as speed_percentile,
        PERCENT_RANK() OVER (ORDER BY avg_shipping_cost DESC) as cost_percentile
    FROM metrics_with_rates
),

peer_metrics AS (
    SELECT
        carrier_id,
        shipping_method_id,
        DENSE_RANK() OVER (PARTITION BY shipping_method_id ORDER BY avg_delivery_days ASC) as peer_rank,
        COUNT(*) OVER (PARTITION BY shipping_method_id) as peer_count,
        AVG(on_time_delivery_rate) OVER (PARTITION BY shipping_method_id) as peer_avg_on_time,
        -- Use DESC so faster carriers (lower days) get higher percentile
        PERCENT_RANK() OVER (PARTITION BY shipping_method_id ORDER BY avg_delivery_days DESC) as peer_speed_percentile
    FROM metrics_with_rates
    WHERE shipping_method_id IS NOT NULL
),

-- Calculate medians for indexes
median_cost AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_shipping_cost) as median_val
    FROM metrics_with_rates
    WHERE avg_shipping_cost IS NOT NULL
),

median_volume AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_shipments) as median_val
    FROM metrics_with_rates
    WHERE total_shipments IS NOT NULL
)

SELECT
    m.carrier_id,
    m.shipping_method_id,
    m.total_shipments::FLOAT as total_shipments,
    m.delivered_shipments::FLOAT as delivered_shipments,
    m.in_transit_shipments::FLOAT as in_transit_shipments,
    m.cancelled_shipments::FLOAT as cancelled_shipments,
    m.total_shipping_cost::FLOAT as total_shipping_cost,
    m.avg_shipping_cost::FLOAT as avg_shipping_cost,
    m.total_weight::FLOAT as total_weight,
    m.avg_weight::FLOAT as avg_weight,
    m.avg_delivery_days::FLOAT as avg_delivery_days,
    m.min_delivery_days::FLOAT as min_delivery_days,
    m.max_delivery_days::FLOAT as max_delivery_days,
    m.on_time_shipments::FLOAT as on_time_shipments,
    m.on_time_delivery_rate::FLOAT as on_time_delivery_rate,
    m.delivery_completion_rate::FLOAT as delivery_completion_rate,

    -- Global percentiles
    gp.speed_percentile::FLOAT as speed_percentile,
    gp.cost_percentile::FLOAT as cost_percentile,

    -- Delivery speed tier classification (waterfall)
    CASE
        WHEN m.slow_pct <= 0.30 AND COALESCE(m.avg_delivery_days, 0) > 8 THEN 'critical'
        WHEN m.slow_pct <= 0.60 OR COALESCE(m.on_time_delivery_rate, 0) < 0.75 THEN 'needs_improvement'
        WHEN m.slow_pct >= 0.80 AND COALESCE(m.on_time_delivery_rate, 0) >= 0.92 THEN 'excellent'
        WHEN COALESCE(m.on_time_delivery_rate, 0) >= 0.85 AND COALESCE(m.avg_delivery_days, 999) <= 5 THEN 'good'
        ELSE 'good'
    END as delivery_speed_tier,

    -- Cost tier classification (waterfall)
    CASE
        WHEN gp.cost_percentile >= 0.80 AND COALESCE(m.delivery_completion_rate, 0) >= 0.90 THEN 'premium'
        WHEN gp.cost_percentile >= 0.60 AND COALESCE(m.avg_shipping_cost, mc.median_val) < mc.median_val THEN 'economical'
        WHEN gp.cost_percentile >= 0.30 THEN 'standard'
        ELSE 'expensive'
    END as cost_tier,

    -- Peer metrics
    COALESCE(p.peer_rank, 1)::FLOAT as peer_rank,
    COALESCE(p.peer_count, 1)::FLOAT as peer_count,
    CASE
        WHEN COALESCE(m.on_time_delivery_rate, 0) > COALESCE(p.peer_avg_on_time, 0) THEN 1
        ELSE 0
    END as above_peer_avg,
    COALESCE(p.peer_speed_percentile, 0.5)::FLOAT as peer_speed_percentile,

    -- Efficiency index (0-100)
    GREATEST(0, LEAST(100,
        (
            -- Fulfillment factor (30%)
            COALESCE(m.delivery_completion_rate, 0) * 0.30 +
            -- Speed factor (25%): 1 - min(days/14, 1)
            GREATEST(0, 1 - LEAST(COALESCE(m.avg_delivery_days, 14) / 14.0, 1.0)) * 0.25 +
            -- On-time factor (25%)
            COALESCE(m.on_time_delivery_rate, 0) * 0.25 +
            -- Cost efficiency factor (20%): 1 - (cost/median - 1), capped 0-1
            GREATEST(0, LEAST(1, 1 - (COALESCE(m.avg_shipping_cost, mc.median_val) / NULLIF(mc.median_val, 0) - 1))) * 0.20
        ) * 100
    ))::FLOAT as carrier_efficiency_index,

    -- Reliability index (0-100)
    CAST(GREATEST(0, LEAST(100,
        (
            -- Completion consistency (40%)
            LEAST(1, GREATEST(0, COALESCE(m.delivery_completion_rate, 0))) * 0.40 +
            -- Speed consistency (30%): lower variance = better
            CASE
                WHEN COALESCE(m.avg_delivery_days, 0) > 0 THEN
                    GREATEST(0, 1 - LEAST((COALESCE(m.max_delivery_days, 0) - COALESCE(m.min_delivery_days, 0)) / m.avg_delivery_days / 2.0, 1.0))
                ELSE 1.0
            END * 0.30 +
            -- Volume handling (30%): relative to median
            LEAST(1, COALESCE(m.total_shipments, 0) / NULLIF(mv.median_val, 0)) * 0.30
        ) * 100
    )) AS FLOAT) as carrier_reliability_index

FROM metrics_with_rates m
LEFT JOIN global_percentiles gp ON m.carrier_id = gp.carrier_id
LEFT JOIN peer_metrics p ON m.carrier_id = p.carrier_id
CROSS JOIN median_cost mc
CROSS JOIN median_volume mv
EOF

# Run dbt
dbt deps
dbt run -s rpt_carrier_performance

if [ "$DB_TYPE" = "snowflake" ]; then
    echo "Creating lowercase metadata views for Snowflake compatibility..."
    cat > "$DBT_PROJECT_DIR/macros/create_lowercase_views.sql" << 'MACROEOF'
{% macro create_lowercase_views() %}
  {% set db = target.database %}
  {% set tables = ['rpt_carrier_performance'] %}
  {% for t in tables %}
    {% do run_query('CREATE OR REPLACE VIEW "' ~ db ~ '"."main"."' ~ t ~ '" AS SELECT * FROM "' ~ db ~ '".MAIN.' ~ t | upper) %}
    {{ log('Created lowercase view: "main"."' ~ t ~ '"', info=True) }}
  {% endfor %}
{% endmacro %}
MACROEOF
    dbt run-operation create_lowercase_views
fi
