#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Create custom schema using admin role (agent role lacks CREATE SCHEMA privilege)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Creating custom schema using admin role..."
    python3 << 'CREATE_SCHEMA_PY'
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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'promo_analytics'
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
db = os.environ['SNOWFLAKE_DATABASE']
try:
    cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema}")
    cur.execute(f"GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    print(f"Successfully created schema {schema} and granted permissions to {agent_role}")
except Exception as e:
    print(f"Warning: Failed to create schema {schema}: {e}")
conn.close()
CREATE_SCHEMA_PY
fi



# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Create dbt project
mkdir -p /app/dbt_project
cd /app/dbt_project

# Initialize dbt project structure
mkdir -p models macros

# Create dbt_project.yml
cat > dbt_project.yml << 'DBTPROJECT'
name: 'promo_lift'
version: '1.0.0'
config-version: 2

profile: 'promo_lift'

model-paths: ["models"]
macro-paths: ["macros"]

models:
  promo_lift:
    +materialized: table
DBTPROJECT

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > ~/.dbt/profiles.yml <<PROFILES
promo_lift:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: promo_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    cat > ~/.dbt/profiles.yml << 'PROFILES'
promo_lift:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: promo_analytics
PROFILES
    echo "Configured DuckDB profile"
fi

# Create the promo_lift_analysis model - use DB-specific date subtraction syntax
if [ "$DB_TYPE" = "snowflake" ]; then
    DATE_SUB_EXPR="DATEADD(day, -365, pd.start_date)"
else
    DATE_SUB_EXPR="pd.start_date - INTERVAL 365 DAY"
fi

cat > models/promo_lift_analysis.sql << MODEL
WITH valid_orders AS (
    -- Filter to valid orders only (exclude test/sample/internal)
    SELECT
        ORDER_ID,
        ORDERED_AT,
        GRAND_TOTAL,
        CAST(ORDERED_AT AS DATE) as order_date
    FROM ORDERS.ORDERS
    WHERE (TEST_ORDER_FLAG IS NULL OR UPPER(CAST(TEST_ORDER_FLAG AS VARCHAR)) NOT IN ('1', 'TRUE', 'T', 'Y', 'YES'))
      AND (SAMPLE_ORDER_FLAG IS NULL OR SAMPLE_ORDER_FLAG = false)
      AND (INTERNAL_ORDER_FLAG IS NULL OR INTERNAL_ORDER_FLAG = false)
),

-- Get products for each promotion (handles product or brand targeting)
promotion_products AS (
    SELECT DISTINCT
        pp.PROMOTION_ID,
        COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) as PRODUCT_ID
    FROM MARKETING.PROMOTION_PRODUCTS pp
    LEFT JOIN PRODUCT.PRODUCTS p ON (
        (pp.PRODUCT_ID IS NOT NULL AND pp.PRODUCT_ID = p.PRODUCT_ID)
        OR (pp.BRAND_ID IS NOT NULL AND pp.BRAND_ID = p.BRAND_ID)
    )
    WHERE COALESCE(pp.PRODUCT_ID, p.PRODUCT_ID) IS NOT NULL
),

-- Count targeted products per promotion
targeted_product_counts AS (
    SELECT
        PROMOTION_ID,
        COUNT(DISTINCT PRODUCT_ID) as targeted_products_count
    FROM promotion_products
    GROUP BY PROMOTION_ID
),

-- Promotion redemption metrics (excluding test/sample/internal orders)
redemption_metrics AS (
    SELECT
        pr.PROMOTION_ID,
        COUNT(*) as redemption_count,
        SUM(pr.DISCOUNT_AMOUNT) as total_discount_given,
        AVG(pr.DISCOUNT_AMOUNT) as avg_discount_per_order
    FROM MARKETING.PROMOTION_REDEMPTIONS pr
    JOIN valid_orders vo ON pr.ORDER_ID = vo.ORDER_ID
    GROUP BY pr.PROMOTION_ID
),

-- Revenue from redeemed orders (sum of GRAND_TOTAL)
redeemed_order_revenue AS (
    SELECT
        pr.PROMOTION_ID,
        SUM(vo.GRAND_TOTAL) as redeemed_order_revenue
    FROM MARKETING.PROMOTION_REDEMPTIONS pr
    JOIN valid_orders vo ON pr.ORDER_ID = vo.ORDER_ID
    GROUP BY pr.PROMOTION_ID
),

-- Promotion details
promo_details AS (
    SELECT
        PROMOTION_ID,
        PROMOTION_NAME,
        CAST(START_DATE AS DATE) as start_date,
        CAST(END_DATE AS DATE) as end_date,
        DATEDIFF('day', CAST(START_DATE AS DATE), CAST(END_DATE AS DATE)) + 1 as promotion_duration_days
    FROM MARKETING.PROMOTIONS
),

-- Historical baseline: daily avg revenue for targeted products in 365 days before promo
baseline_revenue AS (
    SELECT
        pd.PROMOTION_ID,
        SUM(ol.LINE_TOTAL) / 365.0 as baseline_daily_avg
    FROM promo_details pd
    JOIN promotion_products pp ON pd.PROMOTION_ID = pp.PROMOTION_ID
    JOIN ORDERS.ORDER_LINES ol ON pp.PRODUCT_ID = ol.PRODUCT_ID
    JOIN valid_orders vo ON ol.ORDER_ID = vo.ORDER_ID
    WHERE vo.order_date >= ${DATE_SUB_EXPR}
      AND vo.order_date < pd.start_date
    GROUP BY pd.PROMOTION_ID
),

-- Final calculation
final_results AS (
    SELECT
        pd.PROMOTION_ID as promotion_id,
        pd.PROMOTION_NAME as promotion_name,
        pd.promotion_duration_days,
        tpc.targeted_products_count,
        rm.redemption_count,
        ROUND(rm.total_discount_given, 2) as total_discount_given,
        ROUND(rm.avg_discount_per_order, 2) as avg_discount_per_order,
        ROUND(COALESCE(br.baseline_daily_avg, 0), 2) as baseline_daily_avg,
        ROUND(COALESCE(ror.redeemed_order_revenue, 0), 2) as redeemed_order_revenue,
        ROUND(
            COALESCE(ror.redeemed_order_revenue, 0) -
            (COALESCE(br.baseline_daily_avg, 0) * pd.promotion_duration_days),
            2
        ) as estimated_lift,
        CASE
            WHEN rm.total_discount_given > 0 THEN
                ROUND(
                    ((COALESCE(ror.redeemed_order_revenue, 0) -
                      (COALESCE(br.baseline_daily_avg, 0) * pd.promotion_duration_days) -
                      rm.total_discount_given) / rm.total_discount_given) * 100,
                    2
                )
            ELSE NULL
        END as roi_pct
    FROM promo_details pd
    -- INNER JOIN to only include promotions with redemptions
    JOIN redemption_metrics rm ON pd.PROMOTION_ID = rm.PROMOTION_ID
    -- INNER JOIN to only include promotions with targeted products
    JOIN targeted_product_counts tpc ON pd.PROMOTION_ID = tpc.PROMOTION_ID
    LEFT JOIN baseline_revenue br ON pd.PROMOTION_ID = br.PROMOTION_ID
    LEFT JOIN redeemed_order_revenue ror ON pd.PROMOTION_ID = ror.PROMOTION_ID
    WHERE rm.redemption_count >= 1
      AND tpc.targeted_products_count > 0
)

SELECT *
FROM final_results
ORDER BY redemption_count DESC, promotion_name ASC
MODEL

# Run dbt
dbt run

# Export results to CSV
python3 << 'EXPORT'
import os
import pandas as pd

db_type = os.environ.get('DB_TYPE', 'duckdb').lower()

if db_type == 'snowflake':
    import subprocess, base64
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization
    import snowflake.connector

    private_key_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
    private_key_pem = base64.b64decode(private_key_b64)
    passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
    passphrase_bytes = passphrase.encode() if passphrase else None
    p_key = serialization.load_pem_private_key(private_key_pem, password=passphrase_bytes, backend=default_backend())
    pkb = p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )
    conn = snowflake.connector.connect(
        account=os.environ['SNOWFLAKE_ACCOUNT'],
        host=os.environ.get('SNOWFLAKE_HOST') or None,
        user=os.environ['SNOWFLAKE_USER'],
        private_key=pkb,
        database=os.environ['SNOWFLAKE_DATABASE'],
        schema='promo_analytics',
        warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
        role=os.environ.get('SNOWFLAKE_ROLE', None)
    )
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM promo_analytics.promo_lift_analysis ORDER BY redemption_count DESC, promotion_name ASC")
    columns = [desc[0] for desc in cursor.description]
    rows = cursor.fetchall()
    df = pd.DataFrame(rows, columns=columns)
    conn.close()
else:
    import duckdb
    conn = duckdb.connect('/app/database/retail.duckdb', read_only=True)
    df = conn.execute("SELECT * FROM promo_analytics.promo_lift_analysis ORDER BY redemption_count DESC, promotion_name ASC").fetchdf()
    conn.close()

df.to_csv('/app/promo_lift_results.csv', index=False)
print(f"Exported {len(df)} rows to /app/promo_lift_results.csv")
EXPORT
