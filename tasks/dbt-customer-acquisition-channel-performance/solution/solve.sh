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

    # Staging models (int_sales__orders_enriched, stg_orders__orders) are pre-built in Snowflake
    # Just need to write and run the mart model

    # Create the marts directory
    mkdir -p "$DBT_PROJECT_DIR/models/marts/marketing"

    # Write the mart model (no schema: analytics for Snowflake - uses main)
    cat > "$DBT_PROJECT_DIR/models/marts/marketing/rpt_customer_acquisition_channel_performance_fixed.sql" << 'EOF'
{{
    config(
        materialized='table',
        tags=['marketing', 'acquisition']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}
{% set stg_orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_orders__orders') %}

WITH orders_with_attribution AS (
  SELECT
    o.order_id,
    o.customer_id,
    o.ordered_at,
    o.grand_total,
    o.status,
    COALESCE(
      so.attribution_channel,
      CASE
        WHEN LOWER(so.utm_source) = 'google' AND LOWER(so.utm_medium) = 'cpc' THEN 'PAID_SEARCH'
        WHEN LOWER(so.utm_source) = 'google' AND LOWER(so.utm_medium) = 'organic' THEN 'ORGANIC_SEARCH'
        WHEN LOWER(so.utm_source) IN ('facebook', 'instagram') THEN 'SOCIAL_MEDIA'
        WHEN LOWER(so.utm_source) = 'email' OR LOWER(so.utm_medium) = 'email' THEN 'EMAIL'
        WHEN LOWER(so.utm_source) = 'direct' OR (so.utm_source IS NULL AND so.utm_medium IS NULL) THEN 'DIRECT'
        ELSE 'OTHER'
      END
    ) AS acquisition_channel
  FROM {{ orders_rel }} o
  JOIN {{ stg_orders_rel }} so ON o.order_id = so.order_id
  WHERE o.status != 'CANCELLED'
    AND o.customer_id IS NOT NULL
    AND o.ordered_at IS NOT NULL
),

first_orders AS (
  SELECT
    customer_id,
    acquisition_channel,
    ordered_at AS first_order_date
  FROM (
    SELECT
      customer_id,
      acquisition_channel,
      ordered_at,
      ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ordered_at ASC) AS rn
    FROM orders_with_attribution
  ) ranked
  WHERE rn = 1
),

customer_channel_assignments AS (
  SELECT DISTINCT
    customer_id,
    acquisition_channel
  FROM first_orders
),

all_customer_orders AS (
  SELECT
    cca.customer_id,
    cca.acquisition_channel,
    owa.order_id,
    owa.grand_total,
    owa.ordered_at
  FROM customer_channel_assignments cca
  JOIN orders_with_attribution owa ON cca.customer_id = owa.customer_id
  WHERE owa.status != 'CANCELLED'
),

channel_metrics AS (
  SELECT
    acquisition_channel,
    COUNT(DISTINCT customer_id) AS customer_count,
    COUNT(DISTINCT order_id) AS total_orders,
    SUM(grand_total) AS total_revenue,
    COUNT(DISTINCT CASE WHEN order_count >= 2 THEN customer_id END) AS repeat_customers
  FROM (
    SELECT
      acquisition_channel,
      customer_id,
      order_id,
      grand_total,
      COUNT(*) OVER (PARTITION BY customer_id) AS order_count
    FROM all_customer_orders
  ) orders_with_counts
  GROUP BY 1
),

channel_tiers AS (
  SELECT
    *,
    CASE
      WHEN customer_lifetime_value > 500 AND repeat_purchase_rate > 30 THEN 'HIGH_VALUE'
      WHEN customer_count > 100 AND customer_lifetime_value > 200 THEN 'VOLUME'
      WHEN customer_lifetime_value < 100 OR repeat_purchase_rate < 10 THEN 'LOW_QUALITY'
      ELSE 'STANDARD'
    END AS channel_tier
  FROM (
    SELECT
      acquisition_channel,
      customer_count,
      total_orders,
      ROUND(CAST(total_revenue AS DECIMAL(18,2)), 2) AS total_revenue,
      ROUND(CAST(total_revenue AS DECIMAL(18,2)) / NULLIF(total_orders, 0), 2) AS average_order_value,
      ROUND(CAST(total_revenue AS DECIMAL(18,2)) / NULLIF(customer_count, 0), 2) AS customer_lifetime_value,
      ROUND(CAST(total_orders AS DECIMAL(18,2)) / NULLIF(customer_count, 0), 2) AS average_orders_per_customer,
      ROUND(CAST(repeat_customers AS DECIMAL(18,2)) / NULLIF(customer_count, 0) * 100, 2) AS repeat_purchase_rate
    FROM channel_metrics
  ) calculated
)

SELECT
  acquisition_channel,
  CAST(customer_count AS INTEGER) AS customer_count,
  CAST(total_orders AS INTEGER) AS total_orders,
  total_revenue,
  average_order_value,
  customer_lifetime_value,
  average_orders_per_customer,
  repeat_purchase_rate,
  channel_tier
FROM channel_tiers
ORDER BY customer_lifetime_value DESC, customer_count DESC
EOF

    # Run just the mart model
    cd "$DBT_PROJECT_DIR"
    export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"
    dbt deps || echo "deps already installed"
    dbt run --select rpt_customer_acquisition_channel_performance_fixed

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
    dbt run --select int_sales__orders_enriched stg_orders__orders

    echo "Setting up agent project..."
    cd /app
    mkdir -p dbt_project/models/marts/marketing

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

    cat > dbt_project/models/marts/marketing/rpt_customer_acquisition_channel_performance_fixed.sql << 'EOF'
{{
    config(
        materialized='table',
        tags=['marketing', 'acquisition']
    )
}}

{% set orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='int_sales__orders_enriched') %}
{% set stg_orders_rel = adapter.get_relation(database=target.database, schema='main', identifier='stg_orders__orders') %}

WITH orders_with_attribution AS (
  SELECT
    o.order_id,
    o.customer_id,
    o.ordered_at,
    o.grand_total,
    o.status,
    COALESCE(
      so.attribution_channel,
      CASE
        WHEN LOWER(so.utm_source) = 'google' AND LOWER(so.utm_medium) = 'cpc' THEN 'PAID_SEARCH'
        WHEN LOWER(so.utm_source) = 'google' AND LOWER(so.utm_medium) = 'organic' THEN 'ORGANIC_SEARCH'
        WHEN LOWER(so.utm_source) IN ('facebook', 'instagram') THEN 'SOCIAL_MEDIA'
        WHEN LOWER(so.utm_source) = 'email' OR LOWER(so.utm_medium) = 'email' THEN 'EMAIL'
        WHEN LOWER(so.utm_source) = 'direct' OR (so.utm_source IS NULL AND so.utm_medium IS NULL) THEN 'DIRECT'
        ELSE 'OTHER'
      END
    ) AS acquisition_channel
  FROM {{ orders_rel }} o
  JOIN {{ stg_orders_rel }} so ON o.order_id = so.order_id
  WHERE o.status != 'CANCELLED'
    AND o.customer_id IS NOT NULL
    AND o.ordered_at IS NOT NULL
),

first_orders AS (
  SELECT
    customer_id,
    acquisition_channel,
    ordered_at AS first_order_date
  FROM (
    SELECT
      customer_id,
      acquisition_channel,
      ordered_at,
      ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ordered_at ASC) AS rn
    FROM orders_with_attribution
  ) ranked
  WHERE rn = 1
),

customer_channel_assignments AS (
  SELECT DISTINCT
    customer_id,
    acquisition_channel
  FROM first_orders
),

all_customer_orders AS (
  SELECT
    cca.customer_id,
    cca.acquisition_channel,
    owa.order_id,
    owa.grand_total,
    owa.ordered_at
  FROM customer_channel_assignments cca
  JOIN orders_with_attribution owa ON cca.customer_id = owa.customer_id
  WHERE owa.status != 'CANCELLED'
),

channel_metrics AS (
  SELECT
    acquisition_channel,
    COUNT(DISTINCT customer_id) AS customer_count,
    COUNT(DISTINCT order_id) AS total_orders,
    SUM(grand_total) AS total_revenue,
    COUNT(DISTINCT CASE WHEN order_count >= 2 THEN customer_id END) AS repeat_customers
  FROM (
    SELECT
      acquisition_channel,
      customer_id,
      order_id,
      grand_total,
      COUNT(*) OVER (PARTITION BY customer_id) AS order_count
    FROM all_customer_orders
  ) orders_with_counts
  GROUP BY 1
),

channel_tiers AS (
  SELECT
    *,
    CASE
      WHEN customer_lifetime_value > 500 AND repeat_purchase_rate > 30 THEN 'HIGH_VALUE'
      WHEN customer_count > 100 AND customer_lifetime_value > 200 THEN 'VOLUME'
      WHEN customer_lifetime_value < 100 OR repeat_purchase_rate < 10 THEN 'LOW_QUALITY'
      ELSE 'STANDARD'
    END AS channel_tier
  FROM (
    SELECT
      acquisition_channel,
      customer_count,
      total_orders,
      ROUND(CAST(total_revenue AS DECIMAL(18,2)), 2) AS total_revenue,
      ROUND(CAST(total_revenue AS DECIMAL(18,2)) / NULLIF(total_orders, 0), 2) AS average_order_value,
      ROUND(CAST(total_revenue AS DECIMAL(18,2)) / NULLIF(customer_count, 0), 2) AS customer_lifetime_value,
      ROUND(CAST(total_orders AS DECIMAL(18,2)) / NULLIF(customer_count, 0), 2) AS average_orders_per_customer,
      ROUND(CAST(repeat_customers AS DECIMAL(18,2)) / NULLIF(customer_count, 0) * 100, 2) AS repeat_purchase_rate
    FROM channel_metrics
  ) calculated
)

SELECT
  acquisition_channel,
  CAST(customer_count AS INTEGER) AS customer_count,
  CAST(total_orders AS INTEGER) AS total_orders,
  total_revenue,
  average_order_value,
  customer_lifetime_value,
  average_orders_per_customer,
  repeat_purchase_rate,
  channel_tier
FROM channel_tiers
ORDER BY customer_lifetime_value DESC, customer_count DESC
EOF

    cd /app/dbt_project
    dbt run --select rpt_customer_acquisition_channel_performance_fixed

    echo "DuckDB solution complete!"
fi
