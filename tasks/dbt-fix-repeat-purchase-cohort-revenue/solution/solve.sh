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

if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="/app/dbt_models_snowflake"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"

    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Write Snowflake profiles.yml
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
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"

    # Create symlink so verifier tests can find the project at /app/dbt_project
    ln -sfn "$DBT_PROJECT_DIR" /app/dbt_project

    # Staging models (int_sales__orders_enriched) are pre-built in Snowflake
    # Just need to write and run the mart model

    # Create the marts directory
    mkdir -p "$DBT_PROJECT_DIR/models/marts/customer"

    # Write the mart model (no schema: analytics for Snowflake - uses main)
    cat > "$DBT_PROJECT_DIR/models/marts/customer/rpt_repeat_purchase_cohort_revenue_fixed.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['customer', 'cohort', 'revenue']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}

WITH order_deduped AS (
  -- Deduplicate to one row per order_id to prevent fanout in Snowflake
  SELECT
    order_id,
    MIN(customer_id) AS customer_id,
    MIN(CAST(ordered_at AS TIMESTAMP)) AS ordered_at,
    SUM(CAST(grand_total AS DECIMAL(18,2))) AS grand_total
  FROM {{ orders_rel }}
  WHERE ordered_at IS NOT NULL
  GROUP BY order_id
),

orders AS (
  SELECT
    CAST(customer_id AS VARCHAR) AS raw_customer_id,
    COALESCE(CAST(customer_id AS VARCHAR), 'UNK_' || CAST(order_id AS VARCHAR)) AS customer_key,
    order_id,
    ordered_at,
    grand_total
  FROM order_deduped
),

customer_cohorts AS (
  SELECT
    customer_key,
    raw_customer_id,
    CAST(DATE_TRUNC('month', MIN(ordered_at)) AS DATE) AS cohort_month
  FROM orders
  GROUP BY customer_key, raw_customer_id
),

orders_with_cohort AS (
  SELECT
    o.customer_key,
    o.raw_customer_id,
    o.order_id,
    o.ordered_at,
    o.grand_total,
    c.cohort_month,
    CAST(DATE_TRUNC('month', o.ordered_at) AS DATE) AS order_month,
    DATEDIFF('month', c.cohort_month, CAST(DATE_TRUNC('month', o.ordered_at) AS DATE)) AS months_since_cohort
  FROM orders o
  JOIN customer_cohorts c ON o.customer_key = c.customer_key
),

cohort_sizes AS (
  SELECT
    cohort_month,
    COUNT(DISTINCT CASE WHEN raw_customer_id IS NOT NULL THEN customer_key END) AS cohort_size
  FROM customer_cohorts
  GROUP BY cohort_month
),

bucket_stats AS (
  SELECT
    cohort_month,
    months_since_cohort,
    COUNT(DISTINCT CASE WHEN raw_customer_id IS NOT NULL THEN customer_key END) AS active_customers,
    COUNT(DISTINCT order_id) AS orders,
    CAST(SUM(grand_total) AS DECIMAL(18,2)) AS revenue
  FROM orders_with_cohort
  GROUP BY cohort_month, months_since_cohort
)

SELECT
  b.cohort_month,
  CAST(b.months_since_cohort AS INTEGER) AS months_since_cohort,
  s.cohort_size,
  b.active_customers,
  b.orders,
  CAST(b.revenue AS DECIMAL(18,2)) AS revenue,
  CAST(
    SUM(b.revenue) OVER (
      PARTITION BY b.cohort_month
      ORDER BY b.months_since_cohort
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS DECIMAL(18,2)
  ) AS cumulative_revenue
FROM bucket_stats b
JOIN cohort_sizes s ON b.cohort_month = s.cohort_month
ORDER BY b.cohort_month, b.months_since_cohort
EOF

    # Run just the mart model
    cd "$DBT_PROJECT_DIR"
    export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
    dbt deps || echo "deps already installed"
    dbt run --select rpt_repeat_purchase_cohort_revenue_fixed

    echo "Snowflake solution complete!"

else
    # ===== DuckDB mode =====
    echo "Preparing reference models..."
    cd /app/dbt_models_duckdb
    mkdir -p ~/.dbt

    if [ -f profiles.yml ]; then
      cp profiles.yml ~/.dbt/profiles.yml
    else
      cat > ~/.dbt/profiles.yml << 'EOF'
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
EOF
    fi

    dbt deps || echo "deps already installed"
    dbt run --select int_sales__orders_enriched

    echo "Setting up agent project..."
    cd /app
    mkdir -p dbt_project/models/marts/customer

    cat > ~/.dbt/profiles.yml << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: analytics
EOF

    cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'
model-paths: ["models"]
EOF

    cat > dbt_project/models/marts/customer/rpt_repeat_purchase_cohort_revenue_fixed.sql << 'EOF'
{{
    config(
        materialized='table',
        tags=['customer', 'cohort', 'revenue']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}

WITH orders AS (
  SELECT
    CAST(customer_id AS VARCHAR) AS raw_customer_id,
    COALESCE(CAST(customer_id AS VARCHAR), 'UNK_' || CAST(order_id AS VARCHAR)) AS customer_key,
    order_id,
    CAST(ordered_at AS TIMESTAMP) AS ordered_at,
    CAST(grand_total AS DECIMAL(18,2)) AS grand_total
  FROM {{ orders_rel }}
  WHERE ordered_at IS NOT NULL
),

customer_cohorts AS (
  SELECT
    customer_key,
    raw_customer_id,
    CAST(date_trunc('month', MIN(ordered_at)) AS DATE) AS cohort_month
  FROM orders
  GROUP BY 1,2
),

orders_with_cohort AS (
  SELECT
    o.customer_key,
    o.raw_customer_id,
    o.order_id,
    o.ordered_at,
    o.grand_total,
    c.cohort_month,
    CAST(date_trunc('month', o.ordered_at) AS DATE) AS order_month,
    DATE_DIFF('month', c.cohort_month, CAST(date_trunc('month', o.ordered_at) AS DATE)) AS months_since_cohort
  FROM orders o
  JOIN customer_cohorts c USING (customer_key)
),

cohort_sizes AS (
  SELECT
    cohort_month,
    COUNT(DISTINCT customer_key) FILTER (WHERE raw_customer_id IS NOT NULL) AS cohort_size
  FROM customer_cohorts
  GROUP BY 1
),

bucket_stats AS (
  SELECT
    cohort_month,
    months_since_cohort,
    COUNT(DISTINCT customer_key) FILTER (WHERE raw_customer_id IS NOT NULL) AS active_customers,
    COUNT(DISTINCT order_id) AS orders,
    ROUND(SUM(grand_total), 2) AS revenue
  FROM orders_with_cohort
  GROUP BY 1,2
)

SELECT
  b.cohort_month,
  CAST(b.months_since_cohort AS INTEGER) AS months_since_cohort,
  s.cohort_size,
  b.active_customers,
  b.orders,
  CAST(b.revenue AS DECIMAL(18,2)) AS revenue,
  CAST(
    ROUND(
      SUM(b.revenue) OVER (
        PARTITION BY b.cohort_month
        ORDER BY b.months_since_cohort
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ),
      2
    ) AS DECIMAL(18,2)
  ) AS cumulative_revenue
FROM bucket_stats b
JOIN cohort_sizes s USING (cohort_month)
ORDER BY b.cohort_month, b.months_since_cohort
EOF

    cd /app/dbt_project
    dbt run --select rpt_repeat_purchase_cohort_revenue_fixed

    echo "DuckDB solution complete!"
fi
