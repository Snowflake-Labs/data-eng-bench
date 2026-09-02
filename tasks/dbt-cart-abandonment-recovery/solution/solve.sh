#!/bin/bash
set -euo pipefail

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

# Pre-create "main" schema and source views for Snowflake
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema and source views..."
    python3 << 'PRECREATE_PY'
import snowflake.connector, os, base64
pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_bytes = base64.b64decode(pk_b64)
from cryptography.hazmat.primitives.serialization import load_pem_private_key
p_key = load_pem_private_key(pk_bytes, password=os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE','').encode() or None)
pk_bytes_der = p_key.private_bytes(
    encoding=__import__('cryptography.hazmat.primitives.serialization',fromlist=['Encoding']).Encoding.DER,
    format=__import__('cryptography.hazmat.primitives.serialization',fromlist=['PrivateFormat']).PrivateFormat.PKCS8,
    encryption_algorithm=__import__('cryptography.hazmat.primitives.serialization',fromlist=['NoEncryption']).NoEncryption()
)
conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pk_bytes_der,
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE']
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ.get('SNOWFLAKE_ROLE','')
# Create lowercase main schema
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f'Created schema "main" in {db}')
except Exception as e:
    print(f'Warning creating main: {e}')
# Create views in main for source tables that live in other schemas
for table_name in ['ABANDONED_CARTS', 'WEB_SESSIONS']:
    try:
        cur.execute(f"""
            SELECT TABLE_SCHEMA FROM {db}.INFORMATION_SCHEMA.TABLES
            WHERE TABLE_NAME = '{table_name}' AND TABLE_TYPE = 'BASE TABLE'
            LIMIT 1
        """)
        row = cur.fetchone()
        if row:
            src_schema = row[0]
            cur.execute(f'CREATE OR REPLACE VIEW {db}.MAIN.{table_name} AS SELECT * FROM {db}.{src_schema}.{table_name}')
            cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.{table_name} TO ROLE {agent_role}')
            print(f'Created view main.{table_name} -> {src_schema}.{table_name}')
        else:
            print(f'WARNING: Table {table_name} not found in any schema')
    except Exception as e:
        print(f'Warning creating view for {table_name}: {e}')
# Create int_sales__orders_enriched view from raw orders data
try:
    cur.execute(f"""
        SELECT TABLE_SCHEMA FROM {db}.INFORMATION_SCHEMA.TABLES
        WHERE TABLE_NAME = 'ORDERS' AND TABLE_SCHEMA != 'INFORMATION_SCHEMA'
        LIMIT 1
    """)
    row = cur.fetchone()
    if row:
        orders_schema = row[0]
        cur.execute(f'''CREATE OR REPLACE VIEW {db}.MAIN.int_sales__orders_enriched AS
            SELECT ORDER_ID, CUSTOMER_ID as customer_id, GRAND_TOTAL as grand_total, ORDERED_AT as ordered_at
            FROM {db}.{orders_schema}.ORDERS''')
        cur.execute(f'GRANT SELECT ON VIEW {db}.MAIN.int_sales__orders_enriched TO ROLE {agent_role}')
        print(f'Created view main.int_sales__orders_enriched from {orders_schema}.ORDERS')
except Exception as e:
    print(f'Warning creating int_sales__orders_enriched: {e}')
cur.close()
conn.close()
PRECREATE_PY
fi

cd "$DBT_PROJECT_DIR"

mkdir -p models/staging/ecommerce
mkdir -p models/intermediate/ecommerce
mkdir -p models/marts/ecommerce
mkdir -p macros

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

cat > models/staging/ecommerce/_sources.yml << 'EOF'
version: 2
sources:
  - name: main
    schema: main
    tables:
      - name: ABANDONED_CARTS
      - name: WEB_SESSIONS
      - name: int_sales__orders_enriched
EOF

cat > macros/calculate_recovery_priority.sql << 'EOF'
{% macro calculate_recovery_priority(cart_value, item_count, hours_since, previous_orders) %}
    LEAST(100, GREATEST(0,
        LEAST(1, {{ cart_value }} / 1000.0) * 40 +
        LEAST(1, {{ item_count }} / 10.0) * 20 +
        (1 - LEAST(1, {{ hours_since }} / 168.0)) * 25 +
        LEAST(1, {{ previous_orders }} / 5.0) * 15
    ))
{% endmacro %}
EOF

# Create staging model with database-type-aware SQL using dbt macros
cat > models/staging/ecommerce/stg_ecommerce__abandoned_carts.sql << 'EOF'
{% set db_type = var('db_type', 'duckdb') %}

WITH reference AS (
    SELECT MAX(ABANDONED_AT) as reference_date FROM {{ source('main', 'ABANDONED_CARTS') }}
),
abandoned AS (
    SELECT
        ac.CART_ID,
        ac.CUSTOMER_ID,
        ac.ABANDONED_AT,
        ac.CART_VALUE,
        ac.ITEM_COUNT,
        ws.DURATION_SECONDS as session_duration_seconds,
        ws.PAGE_VIEWS as page_views,
        ws.DEVICE_TYPE as device_type,
        ws.UTM_SOURCE as utm_source
    FROM {{ source('main', 'ABANDONED_CARTS') }} ac
    LEFT JOIN {{ source('main', 'WEB_SESSIONS') }} ws ON ac.SESSION_ID = ws.SESSION_ID
    CROSS JOIN reference r
    {% if target.type == 'snowflake' %}
    WHERE ac.ABANDONED_AT >= DATEADD(day, -30, r.reference_date)
    {% else %}
    WHERE ac.ABANDONED_AT >= r.reference_date - INTERVAL '30' DAY
    {% endif %}
),
customer_history AS (
    SELECT
        UPPER(customer_id) as customer_id,
        COUNT(*) as previous_orders_count,
        SUM(grand_total) as previous_order_value
    FROM {{ source('main', 'int_sales__orders_enriched') }}
    GROUP BY UPPER(customer_id)
)
SELECT
    a.CART_ID as cart_id,
    a.CUSTOMER_ID as customer_id,
    a.ABANDONED_AT as abandoned_at,
    a.CART_VALUE as cart_value,
    a.ITEM_COUNT as item_count,
    {% if target.type == 'snowflake' %}
    DATEDIFF(hour, a.ABANDONED_AT, r.reference_date) as hours_since_abandonment,
    {% else %}
    CAST((EXTRACT(EPOCH FROM (r.reference_date - a.ABANDONED_AT)) / 3600) AS BIGINT) as hours_since_abandonment,
    {% endif %}
    a.session_duration_seconds,
    a.page_views,
    a.device_type,
    a.utm_source,
    COALESCE(ch.previous_orders_count, 0) as previous_orders_count,
    COALESCE(ch.previous_order_value, 0) as previous_order_value,
    r.reference_date
FROM abandoned a
CROSS JOIN reference r
LEFT JOIN customer_history ch ON a.CUSTOMER_ID = ch.customer_id
EOF

cat > models/intermediate/ecommerce/int_ecommerce__cart_recovery_metrics.sql << 'EOF'
SELECT
    *,
    {{ calculate_recovery_priority('cart_value', 'item_count', 'hours_since_abandonment', 'previous_orders_count') }} as recovery_priority_score,
    CASE
        WHEN cart_value > 500 THEN 'HIGH'
        WHEN cart_value >= 100 THEN 'MEDIUM'
        ELSE 'LOW'
    END as cart_value_segment,
    CASE
        WHEN hours_since_abandonment < 1 THEN 'EARLY'
        WHEN hours_since_abandonment <= 24 THEN 'RECENT'
        WHEN hours_since_abandonment <= 72 THEN 'STALE'
        ELSE 'COLD'
    END as abandonment_timing,
    CASE
        WHEN previous_orders_count = 0 THEN 'NEW'
        WHEN previous_orders_count <= 3 THEN 'RETURNING'
        ELSE 'LOYAL'
    END as customer_segment,
    COALESCE(page_views, 0) * COALESCE(session_duration_seconds, 0) / 60.0 as engagement_level
FROM {{ ref('stg_ecommerce__abandoned_carts') }}
EOF

cat > models/marts/ecommerce/mart_ecommerce__recovery_scorecard.sql << 'EOF'
WITH metrics AS (
    SELECT * FROM {{ ref('int_ecommerce__cart_recovery_metrics') }}
),
percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY cart_value ASC, cart_id) as value_percentile,
        PERCENT_RANK() OVER (ORDER BY hours_since_abandonment DESC, cart_id) as recency_percentile,
        PERCENT_RANK() OVER (ORDER BY recovery_priority_score ASC, cart_id) as priority_percentile
    FROM metrics
),
conversion_index AS (
    SELECT
        *,
        LEAST(100, GREATEST(0,
            LEAST(1, cart_value / 1000.0) * 30 +
            LEAST(1, previous_orders_count / 10.0) * 25 +
            LEAST(1, engagement_level / 300.0) * 25 +
            (1 - LEAST(1, hours_since_abandonment / 168.0)) * 20
        )) as conversion_likelihood_index,
        CASE
            WHEN COALESCE(priority_percentile, 0) >= 0.75 AND COALESCE(hours_since_abandonment, 999) < 24 AND COALESCE(cart_value, 0) > 200 THEN 'hot_lead'
            WHEN COALESCE(priority_percentile, 0) >= 0.50 OR (COALESCE(cart_value, 0) > 100 AND COALESCE(hours_since_abandonment, 999) < 48) THEN 'warm_lead'
            WHEN COALESCE(priority_percentile, 0) >= 0.30 OR COALESCE(hours_since_abandonment, 999) < 72 THEN 'follow_up'
            ELSE 'low_priority'
        END as recovery_tier
    FROM percentiles
),
peers AS (
    SELECT
        c.*,
        RANK() OVER (PARTITION BY device_type ORDER BY recovery_priority_score DESC, cart_id) as device_recovery_rank,
        COUNT(*) OVER (PARTITION BY device_type) as device_peer_count,
        AVG(cart_value) OVER (PARTITION BY device_type) as device_avg_value
    FROM conversion_index c
)
SELECT
    cart_id, customer_id, abandoned_at, cart_value, item_count, hours_since_abandonment,
    session_duration_seconds, page_views, device_type, utm_source, previous_orders_count,
    previous_order_value, recovery_priority_score, cart_value_segment, abandonment_timing,
    customer_segment, engagement_level, value_percentile, recency_percentile, priority_percentile,
    recovery_tier, conversion_likelihood_index, device_recovery_rank, device_peer_count,
    CASE WHEN cart_value > device_avg_value THEN 1 ELSE 0 END as above_device_avg_value
FROM peers
EOF

# Override generate_schema_name to keep all models in target schema (for Snowflake)
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'SCHEMAEOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ target.schema }}
{%- endmacro %}
SCHEMAEOF
    echo "Added generate_schema_name macro to keep all models in target schema"
fi

dbt deps
dbt run -s stg_ecommerce__abandoned_carts int_ecommerce__cart_recovery_metrics mart_ecommerce__recovery_scorecard
