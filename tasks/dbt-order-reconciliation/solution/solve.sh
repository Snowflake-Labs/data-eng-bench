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

# Set dbt project directory (standalone project, not the existing one)
DBT_PROJECT_DIR="/app/dbt_project"

echo "Using dbt project: $DBT_PROJECT_DIR"

# Create dbt project directory
mkdir -p $DBT_PROJECT_DIR/models/{staging,intermediate,mart}
mkdir -p $DBT_PROJECT_DIR/macros

# Create dbt_project.yml
cat > $DBT_PROJECT_DIR/dbt_project.yml << 'EOF'
name: 'order_reconciliation'
version: '1.0.0'

profile: 'order_reconciliation'

model-paths: ["models"]
macro-paths: ["macros"]

models:
  order_reconciliation:
    staging:
      +schema: staging
      +materialized: view
    intermediate:
      +schema: intermediate
      +materialized: view
    mart:
      +schema: mart
      +materialized: view
EOF

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > $DBT_PROJECT_DIR/profiles.yml <<PROFILES
order_reconciliation:
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
order_reconciliation:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: main
EOF
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

# Create generate_schema_name macro - return custom schema directly (tests expect staging/intermediate/mart)
cat > $DBT_PROJECT_DIR/macros/generate_schema_name.sql << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema | trim }}
    {%- endif -%}
{%- endmacro %}
EOF

# Pre-create schemas for Snowflake (agent role can't CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    python3 << 'PRECREATE_SCHEMAS'
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
for schema in ['staging', 'intermediate', 'mart', '"main"']:
    try:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}.{schema}')
        cur.execute(f'GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}')
        print(f'Created schema {schema}')
    except Exception as e:
        print(f'Warning creating {schema}: {e}')
cur.close()
conn.close()
PRECREATE_SCHEMAS
fi

# Create sources.yml
cat > $DBT_PROJECT_DIR/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: orders
    schema: ORDERS
    tables:
      - name: ORDERS
      - name: ORDER_LINES
      - name: ORDER_CANCELLATIONS
EOF

# ============================================================
# STAGING MODELS
# ============================================================

cat > $DBT_PROJECT_DIR/models/staging/stg_orders.sql << 'EOF'
WITH source AS (
    SELECT * FROM {{ source('orders', 'ORDERS') }}
)

SELECT
    TRIM(order_id) AS order_id,
    TRIM(order_source) AS order_source,
    COALESCE(subtotal, 0) AS subtotal,
    COALESCE(discount_total, 0) AS discount_total,
    COALESCE(shipping_total, 0) AS shipping_total,
    COALESCE(tax_total, 0) AS tax_total,
    COALESCE(grand_total, 0) AS grand_total,
    TRIM(status) AS status,
    ordered_at
FROM source
EOF

cat > $DBT_PROJECT_DIR/models/staging/stg_order_lines.sql << 'EOF'
WITH source AS (
    SELECT * FROM {{ source('orders', 'ORDER_LINES') }}
)

SELECT
    TRIM(order_line_id) AS order_line_id,
    TRIM(order_id) AS order_id,
    COALESCE(quantity_ordered, 0) AS quantity_ordered,
    COALESCE(unit_price, 0) AS unit_price,
    COALESCE(discount_amount, 0) AS discount_amount,
    COALESCE(tax_amount, 0) AS tax_amount,
    COALESCE(line_total, 0) AS line_total
FROM source
EOF

cat > $DBT_PROJECT_DIR/models/staging/stg_order_cancellations.sql << 'EOF'
WITH source AS (
    SELECT * FROM {{ source('orders', 'ORDER_CANCELLATIONS') }}
)

SELECT
    TRIM(source.cancellation_id) AS cancellation_id,
    TRIM(source.order_id) AS order_id,
    source.cancelled_at,
    CAST(NULL AS VARCHAR) AS reason
FROM source
EOF

# ============================================================
# INTERMEDIATE MODELS
# ============================================================

cat > $DBT_PROJECT_DIR/models/intermediate/int_orders_enriched.sql << 'EOF'
WITH orders AS (
    SELECT * FROM {{ ref('stg_orders') }}
),

order_lines AS (
    SELECT * FROM {{ ref('stg_order_lines') }}
),

cancellations AS (
    SELECT DISTINCT order_id FROM {{ ref('stg_order_cancellations') }}
),

-- Aggregate order lines, only for lines with valid orders (INNER JOIN handles orphans)
line_aggregates AS (
    SELECT
        ol.order_id,
        SUM(ol.line_total) AS line_subtotal,
        SUM(ol.tax_amount) AS line_tax,
        COUNT(*) AS line_count
    FROM order_lines ol
    INNER JOIN orders o ON ol.order_id = o.order_id
    GROUP BY ol.order_id
)

SELECT
    o.order_id,
    o.order_source,
    CASE WHEN c.order_id IS NOT NULL THEN 1 ELSE 0 END AS is_cancelled,
    o.subtotal,
    o.grand_total,
    o.tax_total,
    COALESCE(la.line_subtotal, 0) AS line_subtotal,
    COALESCE(la.line_tax, 0) AS line_tax,
    COALESCE(la.line_count, 0) AS line_count,
    CASE WHEN COALESCE(la.line_count, 0) > 0 THEN 1 ELSE 0 END AS has_lines
FROM orders o
LEFT JOIN line_aggregates la ON o.order_id = la.order_id
LEFT JOIN cancellations c ON o.order_id = c.order_id
EOF

# ============================================================
# MART MODELS
# ============================================================

cat > $DBT_PROJECT_DIR/models/mart/mart_order_totals.sql << 'EOF'
WITH enriched_orders AS (
    SELECT * FROM {{ ref('int_orders_enriched') }}
)

SELECT
    order_id,
    order_source,
    is_cancelled,
    subtotal AS header_subtotal,
    grand_total AS header_grand_total,
    line_subtotal,
    line_count,
    subtotal - line_subtotal AS subtotal_variance,
    CASE WHEN subtotal - line_subtotal != 0 THEN 1 ELSE 0 END AS has_variance,
    tax_total AS header_tax,
    line_tax,
    tax_total - line_tax AS tax_variance,
    CASE WHEN tax_total - line_tax != 0 THEN 1 ELSE 0 END AS has_tax_variance
FROM enriched_orders
EOF

cat > $DBT_PROJECT_DIR/models/mart/mart_revenue_by_source.sql << 'EOF'
WITH enriched_orders AS (
    SELECT * FROM {{ ref('int_orders_enriched') }}
),

order_lines AS (
    SELECT * FROM {{ ref('stg_order_lines') }}
),

-- Non-cancelled orders only
active_orders AS (
    SELECT *
    FROM enriched_orders
    WHERE is_cancelled = 0
),

order_agg AS (
    SELECT
        order_source,
        COUNT(*) AS order_count,
        SUM(grand_total) AS total_revenue
    FROM active_orders
    GROUP BY order_source
),

line_agg AS (
    SELECT
        ao.order_source,
        SUM(ol.quantity_ordered) AS total_items
    FROM order_lines ol
    INNER JOIN active_orders ao ON ol.order_id = ao.order_id
    GROUP BY ao.order_source
)

SELECT
    oa.order_source,
    oa.order_count,
    oa.total_revenue,
    COALESCE(la.total_items, 0) AS total_items,
    CASE
        WHEN oa.order_count = 0 THEN 0
        ELSE oa.total_revenue / oa.order_count
    END AS avg_order_value
FROM order_agg oa
LEFT JOIN line_agg la ON oa.order_source = la.order_source
EOF

cat > $DBT_PROJECT_DIR/models/mart/mart_variance_details.sql << 'EOF'
WITH order_totals AS (
    SELECT
        order_id,
        order_source,
        subtotal AS header_subtotal,
        line_subtotal,
        subtotal - line_subtotal AS subtotal_variance,
        tax_total AS header_tax,
        line_tax,
        tax_total - line_tax AS tax_variance
    FROM {{ ref('int_orders_enriched') }}
)

SELECT
    order_id,
    order_source,
    header_subtotal,
    line_subtotal,
    subtotal_variance,
    CASE
        WHEN header_subtotal = 0 THEN 0
        ELSE (subtotal_variance / header_subtotal) * 100
    END AS subtotal_variance_pct,
    header_tax,
    line_tax,
    tax_variance,
    CASE
        WHEN header_tax = 0 THEN 0
        ELSE (tax_variance / header_tax) * 100
    END AS tax_variance_pct
FROM order_totals
WHERE subtotal_variance != 0 OR tax_variance != 0
EOF

# Run dbt
cd $DBT_PROJECT_DIR
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
dbt run --profiles-dir .

echo "Solution complete!"
