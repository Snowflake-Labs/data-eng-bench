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

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi
echo "Using dbt project: $DBT_PROJECT_DIR"

# Build reference models first
echo "Preparing reference models..."
cd "$DBT_PROJECT_DIR"

# Create profiles.yml based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
else
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
fi

export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps || echo "deps already installed"
dbt run --select int_sales__order_lines int_sales__orders_enriched

# Create custom schema using admin role (agent role may lack CREATE SCHEMA privilege)
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
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'analytics'
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

echo "Setting up agent project..."
PROJECT_DIR="/app/dbt_project"
mkdir -p "${PROJECT_DIR}/models/marts/products"
mkdir -p "${PROJECT_DIR}/models/marts/customer"

# Symlink so dbt_project points to the right backend project for model resolution
ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project_backend

cat > "${PROJECT_DIR}/dbt_project.yml" << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'
model-paths: ["models"]
EOF

# Create profiles.yml for the agent project
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > "${PROJECT_DIR}/profiles.yml" <<PROFILES
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
      schema: analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
else
    cat > "${PROJECT_DIR}/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: analytics
      threads: 4
PROFILES
fi

# Override generate_schema_name for Snowflake compatibility
mkdir -p "${PROJECT_DIR}/macros/utils"
cat > "${PROJECT_DIR}/macros/utils/generate_schema_name.sql" << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# Model 1: Base Cross-Sell Insights with Advanced Metrics
# This SQL is ANSI compatible for both DuckDB and Snowflake
cat > "${PROJECT_DIR}/models/marts/products/rpt_cross_sell_insights.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['products', 'cross_sell']
    )
}}

WITH order_skus AS (
  SELECT DISTINCT
    ol.order_id,
    ol.sku
  FROM main.int_sales__order_lines ol
  WHERE ol.sku IS NOT NULL
    AND ol.order_id IS NOT NULL
),

eligible_orders AS (
  SELECT order_id
  FROM order_skus
  GROUP BY 1
  HAVING COUNT(*) >= 2
),

os AS (
  SELECT o.order_id, o.sku
  FROM order_skus o
  JOIN eligible_orders e USING (order_id)
  JOIN main.int_sales__orders_enriched ord ON ord.order_id = o.order_id
  WHERE COALESCE(ord.is_cancelled, 0) = 0
),

total AS (
  SELECT COUNT(DISTINCT order_id) AS total_orders
  FROM os
),

total_revenue AS (
  SELECT SUM(o.grand_total) AS total_revenue_all_eligible
  FROM main.int_sales__orders_enriched o
  JOIN eligible_orders e ON e.order_id = o.order_id
  WHERE COALESCE(o.is_cancelled, 0) = 0
),

sku_counts AS (
  SELECT
    sku,
    COUNT(DISTINCT order_id) AS orders_with_sku
  FROM os
  GROUP BY 1
),

pairs AS (
  SELECT
    LEAST(a.sku, b.sku) AS sku_a,
    GREATEST(a.sku, b.sku) AS sku_b,
    a.order_id
  FROM os a
  JOIN os b
    ON a.order_id = b.order_id
   AND a.sku < b.sku
),

pair_counts AS (
  SELECT
    sku_a,
    sku_b,
    COUNT(DISTINCT order_id) AS orders_with_both
  FROM pairs
  GROUP BY 1,2
),

pair_revenue AS (
  SELECT
    p.sku_a,
    p.sku_b,
    COUNT(DISTINCT p.order_id) AS orders_with_both,
    SUM(o.grand_total) AS total_revenue_with_both,
    AVG(o.grand_total) AS avg_revenue_per_order_with_both
  FROM pairs p
  JOIN main.int_sales__orders_enriched o ON o.order_id = p.order_id
  WHERE COALESCE(o.is_cancelled, 0) = 0
  GROUP BY 1,2
),

pair_quantities AS (
  SELECT
    p.sku_a,
    p.sku_b,
    p.order_id,
    SUM(ol.quantity_ordered) AS order_qty
  FROM pairs p
  JOIN main.int_sales__order_lines ol ON ol.order_id = p.order_id
  GROUP BY 1,2,3
),

pair_avg_qty AS (
  SELECT
    sku_a,
    sku_b,
    AVG(order_qty) AS avg_quantity_per_order_with_both
  FROM pair_quantities
  GROUP BY 1,2
),

pair_daily_counts AS (
  SELECT
    p.sku_a,
    p.sku_b,
    CAST(o.ordered_at AS DATE) AS order_date,
    COUNT(DISTINCT p.order_id) AS daily_orders
  FROM pairs p
  JOIN main.int_sales__orders_enriched o ON o.order_id = p.order_id
  WHERE COALESCE(o.is_cancelled, 0) = 0
  GROUP BY 1,2,3
),

pair_max_daily AS (
  SELECT
    sku_a,
    sku_b,
    MAX(daily_orders) AS max_orders_in_single_day
  FROM pair_daily_counts
  GROUP BY 1,2
),

filtered_pairs AS (
  SELECT
    pc.sku_a,
    pc.sku_b,
    pc.orders_with_both,
    sa.orders_with_sku AS orders_with_a,
    sb.orders_with_sku AS orders_with_b,
    pr.total_revenue_with_both,
    pr.avg_revenue_per_order_with_both,
    COALESCE(pq.avg_quantity_per_order_with_both, 0) AS avg_quantity_per_order_with_both,
    COALESCE(pmd.max_orders_in_single_day, 0) AS max_orders_in_single_day,
    CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8)) AS support_raw,
    CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku + sb.orders_with_sku - pc.orders_with_both AS DECIMAL(18,8)) AS jaccard_raw
  FROM pair_counts pc
  JOIN sku_counts sa ON pc.sku_a = sa.sku
  JOIN sku_counts sb ON pc.sku_b = sb.sku
  LEFT JOIN pair_revenue pr ON pr.sku_a = pc.sku_a AND pr.sku_b = pc.sku_b
  LEFT JOIN pair_avg_qty pq ON pq.sku_a = pc.sku_a AND pq.sku_b = pc.sku_b
  LEFT JOIN pair_max_daily pmd ON pmd.sku_a = pc.sku_a AND pmd.sku_b = pc.sku_b
  CROSS JOIN total t
  WHERE pc.orders_with_both >= 3
    AND CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8)) >= 0.005
    AND CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku + sb.orders_with_sku - pc.orders_with_both AS DECIMAL(18,8)) >= 0.001
)

SELECT
  fp.sku_a,
  fp.sku_b,
  CAST(fp.orders_with_a AS INTEGER) AS orders_with_a,
  CAST(fp.orders_with_b AS INTEGER) AS orders_with_b,
  CAST(fp.orders_with_both AS INTEGER) AS orders_with_both,
  CAST(ROUND(fp.support_raw, 6) AS DECIMAL(18,6)) AS support,
  CAST(ROUND(CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_a AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS confidence_a_to_b,
  CAST(ROUND(CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_b AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS confidence_b_to_a,
  CAST(
    CASE
      WHEN fp.orders_with_b > 0 AND t.total_orders > 0 THEN
        ROUND(
          (CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_a AS DECIMAL(18,8))) /
          (CAST(fp.orders_with_b AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8))),
          6
        )
      ELSE NULL
    END
    AS DECIMAL(18,6)
  ) AS lift_a_to_b,
  CAST(
    CASE
      WHEN fp.orders_with_a > 0 AND t.total_orders > 0 THEN
        ROUND(
          (CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_b AS DECIMAL(18,8))) /
          (CAST(fp.orders_with_a AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8))),
          6
        )
      ELSE NULL
    END
    AS DECIMAL(18,6)
  ) AS lift_b_to_a,
  CAST(
    CASE
      WHEN fp.orders_with_a > 0 AND t.total_orders > 0 AND
           CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_a AS DECIMAL(18,8)) < 1.0 THEN
        ROUND(
          (1.0 - CAST(fp.orders_with_b AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8))) /
          (1.0 - CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_a AS DECIMAL(18,8))),
          6
        )
      ELSE NULL
    END
    AS DECIMAL(18,6)
  ) AS conviction_a_to_b,
  CAST(
    CASE
      WHEN t.total_orders > 0 THEN
        ROUND(
          (CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8))) -
          (CAST(fp.orders_with_a AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8))) *
          (CAST(fp.orders_with_b AS DECIMAL(18,8)) / CAST(t.total_orders AS DECIMAL(18,8))),
          6
        )
      ELSE NULL
    END
    AS DECIMAL(18,6)
  ) AS leverage_a_to_b,
  CAST(
    ROUND(
      0.5 * (
        CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_a AS DECIMAL(18,8)) +
        CAST(fp.orders_with_both AS DECIMAL(18,8)) / CAST(fp.orders_with_b AS DECIMAL(18,8))
      ),
      6
    )
    AS DECIMAL(18,6)
  ) AS kulczynski_measure,
  CAST(ROUND(fp.jaccard_raw, 6) AS DECIMAL(18,6)) AS jaccard_coefficient,
  CAST(
    ROUND(
      CAST(fp.orders_with_both AS DECIMAL(18,8)) /
      NULLIF(SQRT(CAST(fp.orders_with_a AS DECIMAL(18,8)) * CAST(fp.orders_with_b AS DECIMAL(18,8))), 0),
      6
    )
    AS DECIMAL(18,6)
  ) AS cosine_similarity,
  CAST(COALESCE(fp.avg_revenue_per_order_with_both, 0) AS DECIMAL(18,2)) AS avg_revenue_per_order_with_both,
  CAST(COALESCE(fp.total_revenue_with_both, 0) AS DECIMAL(18,2)) AS total_revenue_with_both,
  CAST(
    CASE
      WHEN tr.total_revenue_all_eligible > 0 THEN
        ROUND(CAST(fp.total_revenue_with_both AS DECIMAL(18,8)) / CAST(tr.total_revenue_all_eligible AS DECIMAL(18,8)), 6)
      ELSE 0
    END
    AS DECIMAL(18,6)
  ) AS revenue_weighted_support,
  CAST(COALESCE(fp.avg_quantity_per_order_with_both, 0) AS DECIMAL(18,2)) AS avg_quantity_per_order_with_both,
  CAST(COALESCE(fp.max_orders_in_single_day, 0) AS INTEGER) AS max_orders_in_single_day
FROM filtered_pairs fp
CROSS JOIN total t
CROSS JOIN total_revenue tr
ORDER BY fp.orders_with_both DESC, fp.sku_a, fp.sku_b
EOF

# Model 2: Cross-Sell Trends with Temporal Decay
# Use Jinja for DATEDIFF syntax difference between DuckDB and Snowflake
cat > "${PROJECT_DIR}/models/marts/products/rpt_cross_sell_trends.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['products', 'cross_sell', 'trends']
    )
}}

WITH base_pairs AS (
  SELECT DISTINCT sku_a, sku_b
  FROM {{ ref('rpt_cross_sell_insights') }}
),

order_skus AS (
  SELECT DISTINCT
    ol.order_id,
    ol.sku,
    EXTRACT(YEAR FROM o.ordered_at) AS year,
    EXTRACT(QUARTER FROM o.ordered_at) AS quarter,
    EXTRACT(MONTH FROM o.ordered_at) AS month,
    o.ordered_at
  FROM main.int_sales__order_lines ol
  JOIN main.int_sales__orders_enriched o ON o.order_id = ol.order_id
  WHERE ol.sku IS NOT NULL
    AND ol.order_id IS NOT NULL
    AND o.ordered_at IS NOT NULL
    AND COALESCE(o.is_cancelled, 0) = 0
),

eligible_orders_q AS (
  SELECT order_id, year, quarter, month
  FROM order_skus
  GROUP BY 1, 2, 3, 4
  HAVING COUNT(*) >= 2
),

os_q AS (
  SELECT o.order_id, o.sku, o.year, o.quarter, o.month, o.ordered_at
  FROM order_skus o
  JOIN eligible_orders_q e ON e.order_id = o.order_id AND e.year = o.year AND e.quarter = o.quarter AND e.month = o.month
),

global_max_date AS (
  SELECT MAX(ordered_at) AS ref_date
  FROM main.int_sales__orders_enriched
  WHERE COALESCE(is_cancelled, 0) = 0
),

quarterly_totals AS (
  SELECT year, quarter, month, COUNT(DISTINCT order_id) AS total_orders
  FROM eligible_orders_q
  GROUP BY 1, 2, 3
),

pairs_q AS (
  SELECT
    LEAST(a.sku, b.sku) AS sku_a,
    GREATEST(a.sku, b.sku) AS sku_b,
    a.order_id,
    a.year,
    a.quarter,
    a.month,
    a.ordered_at
  FROM os_q a
  JOIN os_q b
    ON a.order_id = b.order_id
   AND a.year = b.year
   AND a.quarter = b.quarter
   AND a.month = b.month
   AND a.sku < b.sku
  JOIN base_pairs bp ON bp.sku_a = LEAST(a.sku, b.sku) AND bp.sku_b = GREATEST(a.sku, b.sku)
),

pair_counts_q AS (
  SELECT
    sku_a,
    sku_b,
    year,
    quarter,
    month,
    COUNT(DISTINCT order_id) AS orders_with_both,
    MAX(ordered_at) AS max_order_date
  FROM pairs_q
  GROUP BY 1, 2, 3, 4, 5
),

sku_counts_q AS (
  SELECT
    sku,
    year,
    quarter,
    month,
    COUNT(DISTINCT order_id) AS orders_with_sku
  FROM os_q
  GROUP BY 1, 2, 3, 4
),

decay_weights AS (
  SELECT
    sku_a,
    sku_b,
    {% if target.type == 'snowflake' %}
    MAX(EXP(-0.1 * DATEDIFF(day, max_order_date, (SELECT ref_date FROM global_max_date)))) AS max_decay
    {% else %}
    MAX(EXP(-0.1 * DATEDIFF('day', max_order_date, (SELECT ref_date FROM global_max_date)))) AS max_decay
    {% endif %}
  FROM pair_counts_q
  GROUP BY 1, 2
),

quarterly_metrics AS (
  SELECT
    pc.sku_a,
    pc.sku_b,
    pc.year,
    pc.quarter,
    pc.month,
    pc.orders_with_both,
    CAST(ROUND(CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(qt.total_orders AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS support,
    CAST(ROUND(CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS confidence_a_to_b,
    CAST(
      CASE
        WHEN sb.orders_with_sku > 0 AND qt.total_orders > 0 THEN
          ROUND(
            (CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku AS DECIMAL(18,8))) /
            (CAST(sb.orders_with_sku AS DECIMAL(18,8)) / CAST(qt.total_orders AS DECIMAL(18,8))),
            6
          )
        ELSE NULL
      END
      AS DECIMAL(18,6)
    ) AS lift_a_to_b,
    {% if target.type == 'snowflake' %}
    EXP(-0.1 * DATEDIFF(day, pc.max_order_date, (SELECT ref_date FROM global_max_date))) / NULLIF(dw.max_decay, 0) AS exponential_decay_weight
    {% else %}
    EXP(-0.1 * DATEDIFF('day', pc.max_order_date, (SELECT ref_date FROM global_max_date))) / NULLIF(dw.max_decay, 0) AS exponential_decay_weight
    {% endif %}
  FROM pair_counts_q pc
  JOIN sku_counts_q sa ON sa.sku = pc.sku_a AND sa.year = pc.year AND sa.quarter = pc.quarter AND sa.month = pc.month
  JOIN sku_counts_q sb ON sb.sku = pc.sku_b AND sb.year = pc.year AND sb.quarter = pc.quarter AND sb.month = pc.month
  JOIN quarterly_totals qt ON qt.year = pc.year AND qt.quarter = pc.quarter AND qt.month = pc.month
  JOIN decay_weights dw ON dw.sku_a = pc.sku_a AND dw.sku_b = pc.sku_b
)

SELECT
  qm.sku_a,
  qm.sku_b,
  CAST(qm.year AS INTEGER) AS year,
  CAST(qm.quarter AS INTEGER) AS quarter,
  CAST(qm.month AS INTEGER) AS month,
  CAST(qm.orders_with_both AS INTEGER) AS orders_with_both,
  qm.support,
  qm.confidence_a_to_b,
  qm.lift_a_to_b,
  CAST(
    CASE
      WHEN qm.quarter = 1 THEN NULL
      WHEN prev_q.support IS NULL THEN NULL
      WHEN prev_q.support = 0 THEN NULL
      ELSE ROUND((qm.support - prev_q.support) / prev_q.support, 6)
    END
    AS DECIMAL(18,6)
  ) AS quarter_over_quarter_change,
  CAST(
    CASE
      WHEN prev_m.support IS NULL THEN NULL
      WHEN prev_m.support = 0 THEN NULL
      ELSE ROUND((qm.support - prev_m.support) / prev_m.support, 6)
    END
    AS DECIMAL(18,6)
  ) AS month_over_month_change,
  CAST(ROUND(qm.exponential_decay_weight, 6) AS DECIMAL(18,6)) AS exponential_decay_weight,
  CAST(ROUND(qm.support * qm.exponential_decay_weight, 6) AS DECIMAL(18,6)) AS decay_weighted_support
FROM quarterly_metrics qm
LEFT JOIN quarterly_metrics prev_q
  ON prev_q.sku_a = qm.sku_a
 AND prev_q.sku_b = qm.sku_b
 AND prev_q.year = qm.year
 AND prev_q.quarter = qm.quarter - 1
LEFT JOIN quarterly_metrics prev_m
  ON prev_m.sku_a = qm.sku_a
 AND prev_m.sku_b = qm.sku_b
 AND prev_m.year = qm.year
 AND prev_m.quarter = qm.quarter
 AND prev_m.month = qm.month - 1
ORDER BY qm.sku_a, qm.sku_b, qm.year, qm.quarter, qm.month
EOF

# Model 3: Cross-Sell by Customer Segment with Category Analysis
cat > "${PROJECT_DIR}/models/marts/customer/rpt_cross_sell_by_segment.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['customer', 'cross_sell', 'segmentation']
    )
}}

WITH base_pairs AS (
  SELECT DISTINCT sku_a, sku_b
  FROM {{ ref('rpt_cross_sell_insights') }}
),

customer_lifetime_value AS (
  SELECT
    customer_id,
    SUM(grand_total) AS customer_lifetime_value
  FROM main.int_sales__orders_enriched
  WHERE customer_id IS NOT NULL
    AND COALESCE(is_cancelled, 0) = 0
  GROUP BY customer_id
),

customer_segments AS (
  SELECT
    COALESCE(clv.customer_id, c.customer_id) AS customer_id,
    CASE
      WHEN clv.customer_lifetime_value >= 10000 THEN 'high_value'
      WHEN clv.customer_lifetime_value >= 5000 THEN 'medium_value'
      WHEN clv.customer_lifetime_value >= 1000 THEN 'low_value'
      WHEN clv.customer_lifetime_value IS NULL THEN 'unknown'
      ELSE 'new'
    END AS customer_segment
  FROM main.int_customers__unified c
  LEFT JOIN customer_lifetime_value clv ON c.customer_id = clv.customer_id
),

product_categories AS (
  SELECT DISTINCT
    pv.sku,
    COALESCE(pc.category_name, NULL) AS category
  FROM main.dim_product_variants pv
  LEFT JOIN (
    SELECT DISTINCT product_id, category_id
    FROM (
      SELECT product_id, category_id, ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY is_primary DESC NULLS LAST, sort_order) AS rn
      FROM main.stg_product__product_category_mapping
    ) ranked
    WHERE rn = 1
  ) pcm ON pcm.product_id = pv.product_id
  LEFT JOIN main.stg_product__product_categories pc ON pc.category_id = pcm.category_id
  WHERE pv.sku IS NOT NULL
),

order_skus AS (
  SELECT DISTINCT
    ol.order_id,
    ol.sku,
    o.customer_id
  FROM main.int_sales__order_lines ol
  JOIN main.int_sales__orders_enriched o ON o.order_id = ol.order_id
  WHERE ol.sku IS NOT NULL
    AND ol.order_id IS NOT NULL
    AND COALESCE(o.is_cancelled, 0) = 0
),

eligible_orders AS (
  SELECT order_id
  FROM order_skus
  GROUP BY 1
  HAVING COUNT(*) >= 2
),

os_seg AS (
  SELECT
    o.order_id,
    o.sku,
    cs.customer_segment
  FROM order_skus o
  JOIN eligible_orders e ON e.order_id = o.order_id
  JOIN customer_segments cs ON cs.customer_id = o.customer_id
),

segment_totals AS (
  SELECT
    customer_segment,
    COUNT(DISTINCT order_id) AS total_orders
  FROM os_seg
  GROUP BY 1
),

pairs_seg AS (
  SELECT
    LEAST(a.sku, b.sku) AS sku_a,
    GREATEST(a.sku, b.sku) AS sku_b,
    a.order_id,
    a.customer_segment
  FROM os_seg a
  JOIN os_seg b
    ON a.order_id = b.order_id
   AND a.customer_segment = b.customer_segment
   AND a.sku < b.sku
  JOIN base_pairs bp ON bp.sku_a = LEAST(a.sku, b.sku) AND bp.sku_b = GREATEST(a.sku, b.sku)
),

pair_counts_seg AS (
  SELECT
    sku_a,
    sku_b,
    customer_segment,
    COUNT(DISTINCT order_id) AS orders_with_both
  FROM pairs_seg
  GROUP BY 1, 2, 3
),

sku_counts_seg AS (
  SELECT
    sku,
    customer_segment,
    COUNT(DISTINCT order_id) AS orders_with_sku
  FROM os_seg
  GROUP BY 1, 2
),

pair_revenue_seg AS (
  SELECT
    p.sku_a,
    p.sku_b,
    p.customer_segment,
    AVG(o.grand_total) AS avg_order_value_with_both
  FROM pairs_seg p
  JOIN main.int_sales__orders_enriched o ON o.order_id = p.order_id
  WHERE COALESCE(o.is_cancelled, 0) = 0
  GROUP BY 1, 2, 3
)

SELECT
  pc.customer_segment,
  pc.sku_a,
  pc.sku_b,
  CAST(pc.orders_with_both AS INTEGER) AS orders_with_both,
  CAST(ROUND(CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(st.total_orders AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS support,
  CAST(ROUND(CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS confidence_a_to_b,
  CAST(
    CASE
      WHEN sb.orders_with_sku > 0 AND st.total_orders > 0 THEN
        ROUND(
          (CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku AS DECIMAL(18,8))) /
          (CAST(sb.orders_with_sku AS DECIMAL(18,8)) / CAST(st.total_orders AS DECIMAL(18,8))),
          6
        )
      ELSE NULL
    END
    AS DECIMAL(18,6)
  ) AS lift_a_to_b,
  CAST(COALESCE(pr.avg_order_value_with_both, 0) AS DECIMAL(18,2)) AS avg_order_value_with_both,
  COALESCE(pca.category, NULL) AS category_a,
  COALESCE(pcb.category, NULL) AS category_b,
  CASE
    WHEN pca.category IS NOT NULL AND pcb.category IS NOT NULL AND pca.category = pcb.category THEN 1
    ELSE 0
  END AS same_category_flag,
  CASE
    WHEN pca.category IS NOT NULL AND pcb.category IS NOT NULL AND pca.category != pcb.category THEN
      CAST(
        CASE
          WHEN sb.orders_with_sku > 0 AND st.total_orders > 0 THEN
            ROUND(
              (CAST(pc.orders_with_both AS DECIMAL(18,8)) / CAST(sa.orders_with_sku AS DECIMAL(18,8))) /
              (CAST(sb.orders_with_sku AS DECIMAL(18,8)) / CAST(st.total_orders AS DECIMAL(18,8))),
              6
            )
          ELSE NULL
        END
        AS DECIMAL(18,6)
      )
    ELSE NULL
  END AS cross_category_lift
FROM pair_counts_seg pc
JOIN sku_counts_seg sa ON sa.sku = pc.sku_a AND sa.customer_segment = pc.customer_segment
JOIN sku_counts_seg sb ON sb.sku = pc.sku_b AND sb.customer_segment = pc.customer_segment
JOIN segment_totals st ON st.customer_segment = pc.customer_segment
LEFT JOIN pair_revenue_seg pr ON pr.sku_a = pc.sku_a AND pr.sku_b = pc.sku_b AND pr.customer_segment = pc.customer_segment
LEFT JOIN product_categories pca ON pca.sku = pc.sku_a
LEFT JOIN product_categories pcb ON pcb.sku = pc.sku_b
ORDER BY pc.customer_segment, pc.orders_with_both DESC, pc.sku_a, pc.sku_b
EOF

# Model 4: Cross-Sell Category Hierarchy
cat > "${PROJECT_DIR}/models/marts/products/rpt_cross_sell_category_hierarchy.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['products', 'cross_sell', 'categories']
    )
}}

WITH product_categories AS (
  SELECT DISTINCT
    pv.sku,
    COALESCE(pc.category_name, NULL) AS category
  FROM main.dim_product_variants pv
  LEFT JOIN (
    SELECT DISTINCT product_id, category_id
    FROM (
      SELECT product_id, category_id, ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY is_primary DESC NULLS LAST, sort_order) AS rn
      FROM main.stg_product__product_category_mapping
    ) ranked
    WHERE rn = 1
  ) pcm ON pcm.product_id = pv.product_id
  LEFT JOIN main.stg_product__product_categories pc ON pc.category_id = pcm.category_id
  WHERE pv.sku IS NOT NULL
),

order_skus AS (
  SELECT DISTINCT
    ol.order_id,
    ol.sku
  FROM main.int_sales__order_lines ol
  JOIN main.int_sales__orders_enriched o ON o.order_id = ol.order_id
  WHERE ol.sku IS NOT NULL
    AND ol.order_id IS NOT NULL
    AND COALESCE(o.is_cancelled, 0) = 0
),

order_categories AS (
  SELECT DISTINCT
    os.order_id,
    pc.category
  FROM order_skus os
  JOIN product_categories pc ON pc.sku = os.sku
),

eligible_orders AS (
  SELECT order_id
  FROM order_skus
  GROUP BY 1
  HAVING COUNT(*) >= 2
),

order_cats_filtered AS (
  SELECT oc.order_id, oc.category
  FROM order_categories oc
  JOIN eligible_orders eo ON eo.order_id = oc.order_id
),

category_pairs AS (
  SELECT
    LEAST(a.category, b.category) AS category_a,
    GREATEST(a.category, b.category) AS category_b,
    a.order_id
  FROM order_cats_filtered a
  JOIN order_cats_filtered b
    ON a.order_id = b.order_id
   AND a.category < b.category
),

category_pair_counts AS (
  SELECT
    category_a,
    category_b,
    COUNT(DISTINCT order_id) AS orders_with_both_categories
  FROM category_pairs
  GROUP BY 1, 2
),

category_counts AS (
  SELECT
    category,
    COUNT(DISTINCT order_id) AS orders_with_category
  FROM order_cats_filtered
  GROUP BY 1
),

total_eligible AS (
  SELECT COUNT(DISTINCT order_id) AS total_orders
  FROM eligible_orders
),

category_pair_skus AS (
  SELECT
    cp.category_a,
    cp.category_b,
    cp.order_id,
    COUNT(DISTINCT os.sku) AS skus_in_order
  FROM category_pairs cp
  JOIN order_skus os ON os.order_id = cp.order_id
  JOIN product_categories pc ON pc.sku = os.sku AND (pc.category = cp.category_a OR pc.category = cp.category_b)
  GROUP BY 1, 2, 3
),

category_pair_avg_skus AS (
  SELECT
    category_a,
    category_b,
    AVG(skus_in_order) AS avg_skus_per_order_with_both
  FROM category_pair_skus
  GROUP BY 1, 2
),

category_pair_revenue AS (
  SELECT
    cp.category_a,
    cp.category_b,
    SUM(o.grand_total) AS total_revenue_with_both_categories
  FROM category_pairs cp
  JOIN main.int_sales__orders_enriched o ON o.order_id = cp.order_id
  WHERE COALESCE(o.is_cancelled, 0) = 0
  GROUP BY 1, 2
),

filtered_category_pairs AS (
  SELECT
    cpc.category_a,
    cpc.category_b,
    cpc.orders_with_both_categories,
    ca.orders_with_category AS orders_with_category_a,
    cb.orders_with_category AS orders_with_category_b
  FROM category_pair_counts cpc
  JOIN category_counts ca ON ca.category = cpc.category_a
  JOIN category_counts cb ON cb.category = cpc.category_b
  CROSS JOIN total_eligible te
  WHERE cpc.orders_with_both_categories >= 5
    AND CAST(cpc.orders_with_both_categories AS DECIMAL(18,8)) / CAST(te.total_orders AS DECIMAL(18,8)) >= 0.01
)

SELECT
  fcp.category_a,
  fcp.category_b,
  CAST(fcp.orders_with_category_a AS INTEGER) AS orders_with_category_a,
  CAST(fcp.orders_with_category_b AS INTEGER) AS orders_with_category_b,
  CAST(fcp.orders_with_both_categories AS INTEGER) AS orders_with_both_categories,
  CAST(ROUND(CAST(fcp.orders_with_both_categories AS DECIMAL(18,8)) / CAST(te.total_orders AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS category_support,
  CAST(ROUND(CAST(fcp.orders_with_both_categories AS DECIMAL(18,8)) / CAST(fcp.orders_with_category_a AS DECIMAL(18,8)), 6) AS DECIMAL(18,6)) AS category_confidence_a_to_b,
  CAST(
    CASE
      WHEN fcp.orders_with_category_b > 0 AND te.total_orders > 0 THEN
        ROUND(
          (CAST(fcp.orders_with_both_categories AS DECIMAL(18,8)) / CAST(fcp.orders_with_category_a AS DECIMAL(18,8))) /
          (CAST(fcp.orders_with_category_b AS DECIMAL(18,8)) / CAST(te.total_orders AS DECIMAL(18,8))),
          6
        )
      ELSE NULL
    END
    AS DECIMAL(18,6)
  ) AS category_lift_a_to_b,
  CAST(COALESCE(cpas.avg_skus_per_order_with_both, 0) AS DECIMAL(18,2)) AS avg_skus_per_order_with_both,
  CAST(COALESCE(cpr.total_revenue_with_both_categories, 0) AS DECIMAL(18,2)) AS total_revenue_with_both_categories
FROM filtered_category_pairs fcp
CROSS JOIN total_eligible te
LEFT JOIN category_pair_avg_skus cpas ON cpas.category_a = fcp.category_a AND cpas.category_b = fcp.category_b
LEFT JOIN category_pair_revenue cpr ON cpr.category_a = fcp.category_a AND cpr.category_b = fcp.category_b
ORDER BY fcp.orders_with_both_categories DESC, fcp.category_a, fcp.category_b
EOF

# Clean up existing analytics tables (DuckDB only)
if [ "$DB_TYPE" = "duckdb" ]; then
    echo ">>> Cleaning up existing tables..."
    duckdb "${DUCKDB_PATH}" << 'SQL'
DROP TABLE IF EXISTS analytics.rpt_cross_sell_insights;
DROP TABLE IF EXISTS analytics.rpt_cross_sell_trends;
DROP TABLE IF EXISTS analytics.rpt_cross_sell_by_segment;
DROP TABLE IF EXISTS analytics.rpt_cross_sell_category_hierarchy;
DROP TABLE IF EXISTS ANALYTICS.rpt_cross_sell_insights;
DROP TABLE IF EXISTS ANALYTICS.rpt_cross_sell_trends;
DROP TABLE IF EXISTS ANALYTICS.rpt_cross_sell_by_segment;
DROP TABLE IF EXISTS ANALYTICS.rpt_cross_sell_category_hierarchy;
SQL
fi

cd "${PROJECT_DIR}"
export DBT_PROFILES_DIR="${PROJECT_DIR}"
dbt deps || true
dbt run --select rpt_cross_sell_insights rpt_cross_sell_trends rpt_cross_sell_by_segment rpt_cross_sell_category_hierarchy --full-refresh

echo "Solution complete!"
