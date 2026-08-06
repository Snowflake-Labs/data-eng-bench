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
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_transforms}"
fi

echo "Preparing reference models..."
echo "Using dbt project: $DBT_PROJECT_DIR"

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
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
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    if [ -f "$DBT_PROJECT_DIR/profiles.yml" ]; then
        cp "$DBT_PROJECT_DIR/profiles.yml" ~/.dbt/profiles.yml
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
fi

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

dbt deps || echo "deps already installed"
dbt run --select int_sales__orders_enriched int_sales__order_lines

echo "Setting up agent project..."
cd /app
mkdir -p dbt_project/models/{staging,intermediate,marts/product}

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key again for agent project profile
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"

    cat > dbt_project/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: ANALYTICS
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    export DBT_PROFILES_DIR="/app/dbt_project"
else
    cat > ~/.dbt/profiles.yml << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: analytics
EOF
fi

cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'
model-paths: ["models"]

models:
  dbt_project:
    staging:
      +materialized: view
    intermediate:
      +materialized: table
    marts:
      +materialized: table
EOF

cat > dbt_project/models/sources.yml << 'EOF'
version: 2

sources:
  - name: orders
    schema: ORDERS
    tables:
      - name: RETURN_LINES
      - name: RETURN_REASONS
EOF

# Create staging model - uses conditional SQL for days_to_return calculation
cat > dbt_project/models/staging/stg_product_returns.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

WITH order_lines AS (
    SELECT
        ol.order_line_id,
        ol.order_id,
        ol.product_id,
        COALESCE(ol.sku, ol.product_id) AS sku,
        ol.quantity_ordered,
        ol.line_total
    FROM main.int_sales__order_lines ol
    WHERE ol.product_id IS NOT NULL
),

orders AS (
    SELECT order_id, ordered_at, customer_id, status
    FROM main.int_sales__orders_enriched
    WHERE status NOT IN ('CANCELLED', 'FAILED')
),

return_lines AS (
    SELECT
        rl.order_line_id,
        rl.quantity_returned,
        rl.reason_id,
        rl.created_at AS return_date
    FROM {{ source('orders', 'RETURN_LINES') }} rl
    WHERE rl.quantity_returned > 0
),

return_reasons AS (
    SELECT reason_id, COALESCE(reason_name, 'UNKNOWN') AS reason_name
    FROM {{ source('orders', 'RETURN_REASONS') }}
)

SELECT
    ol.order_line_id,
    ol.order_id,
    ol.product_id,
    ol.sku,
    o.customer_id,
    o.ordered_at,
    rl.return_date,
    ol.quantity_ordered,
    rl.quantity_returned,
    ol.line_total,
    rr.reason_name AS return_reason,
    CASE
        WHEN rl.return_date >= o.ordered_at
        {% if target.type == 'snowflake' %}
        THEN DATEDIFF('second', o.ordered_at, rl.return_date) / 86400.0
        {% else %}
        THEN EXTRACT(EPOCH FROM (rl.return_date - o.ordered_at)) / 86400.0
        {% endif %}
        ELSE NULL
    END AS days_to_return,
    ol.line_total * (CAST(rl.quantity_returned AS NUMERIC) / NULLIF(ol.quantity_ordered, 0)) AS return_revenue_impact
FROM order_lines ol
INNER JOIN orders o ON ol.order_id = o.order_id
INNER JOIN return_lines rl ON ol.order_line_id = rl.order_line_id
LEFT JOIN return_reasons rr ON rl.reason_id = rr.reason_id
EOF

# Create intermediate model - uses conditional SQL for date casting
cat > dbt_project/models/intermediate/int_product_return_metrics.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

WITH stg_returns AS (
    SELECT * FROM {{ ref('stg_product_returns') }}
),

order_lines_base AS (
    SELECT
        ol.order_line_id,
        ol.order_id,
        ol.product_id,
        COALESCE(ol.sku, ol.product_id) AS sku,
        ol.quantity_ordered,
        CAST(DATE_TRUNC('month', o.ordered_at) AS DATE) AS month_start
    FROM main.int_sales__order_lines ol
    INNER JOIN main.int_sales__orders_enriched o ON ol.order_id = o.order_id
    WHERE ol.product_id IS NOT NULL
      AND o.status NOT IN ('CANCELLED', 'FAILED')
),

monthly_units_ordered AS (
    SELECT
        month_start,
        product_id,
        sku,
        SUM(quantity_ordered) AS units_ordered
    FROM order_lines_base
    GROUP BY 1, 2, 3
),

return_metrics_base AS (
    SELECT
        CAST(DATE_TRUNC('month', ordered_at) AS DATE) AS month_start,
        product_id,
        sku,
        SUM(quantity_returned) AS units_returned,
        SUM(return_revenue_impact) AS return_revenue_impact,
        COUNT(DISTINCT customer_id) AS customers_affected,
        AVG(days_to_return) AS avg_days_to_return,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY days_to_return) AS p25_days_to_return,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY days_to_return) AS p50_days_to_return,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY days_to_return) AS p75_days_to_return,
        SUM(CASE WHEN days_to_return <= 7 THEN 1 ELSE 0 END) AS fast_returns,
        SUM(CASE WHEN days_to_return > 7 AND days_to_return <= 30 THEN 1 ELSE 0 END) AS medium_returns,
        SUM(CASE WHEN days_to_return > 30 THEN 1 ELSE 0 END) AS slow_returns
    FROM stg_returns
    GROUP BY 1, 2, 3
),

order_line_aggregated AS (
    SELECT
        CAST(DATE_TRUNC('month', ordered_at) AS DATE) AS month_start,
        product_id,
        order_line_id,
        SUM(quantity_returned) AS total_quantity_returned,
        MAX(quantity_ordered) AS quantity_ordered
    FROM stg_returns
    GROUP BY 1, 2, 3
),

order_line_return_rates AS (
    SELECT
        month_start,
        product_id,
        CAST(total_quantity_returned AS NUMERIC) / NULLIF(quantity_ordered, 0) AS return_rate_per_line
    FROM order_line_aggregated
),

return_rate_percentiles AS (
    SELECT
        month_start,
        product_id,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY return_rate_per_line) AS p25_return_rate,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY return_rate_per_line) AS p50_return_rate,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY return_rate_per_line) AS p75_return_rate
    FROM order_line_return_rates
    GROUP BY 1, 2
),

return_reasons_by_month AS (
    SELECT
        CAST(DATE_TRUNC('month', ordered_at) AS DATE) AS month_start,
        product_id,
        return_reason,
        COUNT(*) AS reason_count,
        ROW_NUMBER() OVER (
            PARTITION BY CAST(DATE_TRUNC('month', ordered_at) AS DATE), product_id
            ORDER BY COUNT(*) DESC, return_reason
        ) AS rn
    FROM stg_returns
    GROUP BY 1, 2, 3
),

top_reasons AS (
    SELECT
        month_start,
        product_id,
        return_reason AS top_return_reason,
        reason_count AS return_reason_count
    FROM return_reasons_by_month
    WHERE rn = 1
)

SELECT
    COALESCE(muo.month_start, rmb.month_start) AS month_start,
    COALESCE(muo.product_id, rmb.product_id) AS product_id,
    COALESCE(muo.sku, rmb.sku) AS sku,
    CAST(COALESCE(muo.units_ordered, 0) AS INTEGER) AS units_ordered,
    CAST(COALESCE(rmb.units_returned, 0) AS INTEGER) AS units_returned,
    CAST(ROUND(
        CAST(COALESCE(rmb.units_returned, 0) AS NUMERIC) / NULLIF(COALESCE(muo.units_ordered, 0), 0),
        6
    ) AS DECIMAL(10,6)) AS return_rate,
    CAST(ROUND(COALESCE(rmb.return_revenue_impact, 0), 2) AS DECIMAL(18,2)) AS return_revenue_impact,
    CAST(COALESCE(rmb.customers_affected, 0) AS INTEGER) AS customers_affected,
    CAST(ROUND(rmb.avg_days_to_return, 4) AS DECIMAL(12,4)) AS avg_days_to_return,
    CAST(ROUND(rmb.p25_days_to_return, 4) AS DECIMAL(12,4)) AS p25_days_to_return,
    CAST(ROUND(rmb.p50_days_to_return, 4) AS DECIMAL(12,4)) AS p50_days_to_return,
    CAST(ROUND(rmb.p75_days_to_return, 4) AS DECIMAL(12,4)) AS p75_days_to_return,
    CAST(ROUND(COALESCE(rrp.p25_return_rate, 0), 6) AS DECIMAL(10,6)) AS p25_return_rate,
    CAST(ROUND(COALESCE(rrp.p50_return_rate, 0), 6) AS DECIMAL(10,6)) AS p50_return_rate,
    CAST(ROUND(COALESCE(rrp.p75_return_rate, 0), 6) AS DECIMAL(10,6)) AS p75_return_rate,
    CAST(COALESCE(rmb.fast_returns, 0) AS INTEGER) AS fast_returns,
    CAST(COALESCE(rmb.medium_returns, 0) AS INTEGER) AS medium_returns,
    CAST(COALESCE(rmb.slow_returns, 0) AS INTEGER) AS slow_returns,
    tr.top_return_reason,
    CAST(COALESCE(tr.return_reason_count, 0) AS INTEGER) AS return_reason_count
FROM monthly_units_ordered muo
FULL OUTER JOIN return_metrics_base rmb
    ON muo.month_start = rmb.month_start
    AND muo.product_id = rmb.product_id
    AND muo.sku = rmb.sku
LEFT JOIN return_rate_percentiles rrp
    ON COALESCE(muo.month_start, rmb.month_start) = rrp.month_start
    AND COALESCE(muo.product_id, rmb.product_id) = rrp.product_id
LEFT JOIN top_reasons tr
    ON COALESCE(muo.month_start, rmb.month_start) = tr.month_start
    AND COALESCE(muo.product_id, rmb.product_id) = tr.product_id
ORDER BY month_start DESC, product_id
EOF

# Create mart model - uses conditional SQL for DATEDIFF
cat > dbt_project/models/marts/product/rpt_product_return_rates_monthly.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

WITH base AS (
    SELECT * FROM {{ ref('int_product_return_metrics') }}
),

with_trends AS (
    SELECT
        *,
        LAG(return_rate) OVER (PARTITION BY product_id ORDER BY month_start) AS prev_month_return_rate
    FROM base
),

with_cohorts AS (
    SELECT
        *,
        MIN(CASE WHEN units_returned > 0 THEN month_start END) OVER (PARTITION BY product_id) AS first_return_month
    FROM with_trends
)

SELECT
    month_start,
    product_id,
    sku,
    units_ordered,
    units_returned,
    CASE WHEN units_returned = 0 THEN 0 ELSE return_rate END AS return_rate,
    return_revenue_impact,
    customers_affected,
    CASE WHEN units_returned = 0 THEN NULL ELSE avg_days_to_return END AS avg_days_to_return,
    CASE WHEN units_returned = 0 THEN NULL ELSE p25_days_to_return END AS p25_days_to_return,
    CASE WHEN units_returned = 0 THEN NULL ELSE p50_days_to_return END AS p50_days_to_return,
    CASE WHEN units_returned = 0 THEN NULL ELSE p75_days_to_return END AS p75_days_to_return,
    CASE WHEN units_returned = 0 THEN NULL ELSE p25_return_rate END AS p25_return_rate,
    CASE WHEN units_returned = 0 THEN NULL ELSE p50_return_rate END AS p50_return_rate,
    CASE WHEN units_returned = 0 THEN NULL ELSE p75_return_rate END AS p75_return_rate,
    CASE WHEN units_returned = 0 THEN 0 ELSE fast_returns END AS fast_returns,
    CASE WHEN units_returned = 0 THEN 0 ELSE medium_returns END AS medium_returns,
    CASE WHEN units_returned = 0 THEN 0 ELSE slow_returns END AS slow_returns,
    CAST(ROUND(
        CASE WHEN units_returned = 0 THEN 0
             ELSE CAST(fast_returns AS NUMERIC) / NULLIF(units_returned, 0)
        END,
        6
    ) AS DECIMAL(10,6)) AS fast_return_rate,
    CAST(ROUND(
        CASE WHEN units_returned = 0 THEN 0
             ELSE CAST(medium_returns AS NUMERIC) / NULLIF(units_returned, 0)
        END,
        6
    ) AS DECIMAL(10,6)) AS medium_return_rate,
    CAST(ROUND(
        CASE WHEN units_returned = 0 THEN 0
             ELSE CAST(slow_returns AS NUMERIC) / NULLIF(units_returned, 0)
        END,
        6
    ) AS DECIMAL(10,6)) AS slow_return_rate,
    CASE WHEN units_returned = 0 THEN NULL ELSE top_return_reason END AS top_return_reason,
    CASE WHEN units_returned = 0 THEN 0 ELSE return_reason_count END AS return_reason_count,
    prev_month_return_rate,
    CASE
        WHEN prev_month_return_rate IS NULL THEN NULL
        ELSE return_rate - prev_month_return_rate
    END AS mom_return_rate_change,
    CASE
        WHEN prev_month_return_rate IS NULL OR prev_month_return_rate = 0 THEN NULL
        ELSE ROUND(((return_rate - prev_month_return_rate) / NULLIF(prev_month_return_rate, 0)) * 100, 4)
    END AS mom_return_rate_change_pct,
    first_return_month,
    CASE
        WHEN first_return_month IS NULL THEN NULL
        {% if target.type == 'snowflake' %}
        ELSE DATEDIFF('month', first_return_month, month_start)
        {% else %}
        ELSE DATE_DIFF('month', first_return_month, month_start)
        {% endif %}
    END AS months_since_first_return,
    CASE
        WHEN first_return_month IS NULL THEN FALSE
        ELSE month_start = first_return_month
    END AS is_first_return_month
FROM with_cohorts
ORDER BY month_start DESC, product_id
EOF

cd /app/dbt_project
if [ "$DB_TYPE" = "snowflake" ]; then
    export DBT_PROFILES_DIR="/app/dbt_project"
fi
dbt run --select +rpt_product_return_rates_monthly

echo "Solution complete!"
