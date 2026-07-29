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
    MODEL_PATH="$DBT_PROJECT_DIR/models/marts/customer/rpt_customer_retention_risk.sql"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
    MODEL_PATH="$DBT_PROJECT_DIR/models/marts/customer/rpt_customer_retention_risk.sql"
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

# Ensure model directory exists
mkdir -p "$(dirname "$MODEL_PATH")"

# Create complete model from scratch
# NOTE: Uses DATEDIFF which works on both DuckDB and Snowflake
if [ "$DB_TYPE" = "snowflake" ]; then
    # Snowflake version - uses DATEDIFF with different argument order
    cat > "$MODEL_PATH" << 'EOF'
-- Customer Retention Risk Analysis Model with RFM Metrics
-- Snowflake-compatible SQL

-- Get reference date (latest order date in the system)
WITH reference_date AS (
    SELECT MAX(ordered_at) as max_order_date
    FROM main.int_sales__orders_enriched
),

-- Aggregate order metrics per customer
customer_orders AS (
    SELECT
        o.customer_id,
        COUNT(*) as total_orders,
        SUM(o.grand_total) as total_revenue,
        MIN(o.ordered_at) as first_order_date,
        MAX(o.ordered_at) as last_order_date
    FROM main.int_sales__orders_enriched o
    WHERE o.customer_id IS NOT NULL
      AND o.status != 'CANCELLED'
    GROUP BY o.customer_id
),

-- Aggregate return metrics per customer
customer_returns AS (
    SELECT
        r.customer_id,
        COUNT(*) as total_returns,
        SUM(r.REFUND_AMOUNT) as total_refund_amount
    FROM main.stg_orders__returns r
    WHERE r.customer_id IS NOT NULL
    GROUP BY r.customer_id
),

-- Join with customer master data
customer_base AS (
    SELECT
        c.customer_id,
        c.customer_type,
        c.acquisition_source,
        co.total_orders,
        co.total_revenue,
        co.first_order_date,
        co.last_order_date,
        DATEDIFF(day, co.last_order_date, rd.max_order_date) as days_since_last_order,
        DATEDIFF(day, co.first_order_date, rd.max_order_date) as customer_tenure_days,
        COALESCE(cr.total_returns, 0) as total_returns,
        COALESCE(cr.total_refund_amount, 0) as total_refund_amount
    FROM main.stg_customer__customers c
    INNER JOIN customer_orders co ON c.customer_id = co.customer_id
    LEFT JOIN customer_returns cr ON c.customer_id = cr.customer_id
    CROSS JOIN reference_date rd
),

-- Calculate derived metrics
customer_metrics AS (
    SELECT
        *,
        total_revenue / NULLIF(total_orders, 0) as avg_order_value,
        total_orders / NULLIF(customer_tenure_days / 30.0, 0) as order_frequency,
        total_revenue - total_refund_amount as net_revenue,
        CAST(total_returns AS FLOAT) / NULLIF(total_orders, 0) as return_rate
    FROM customer_base
),

-- Add annualized revenue
customer_full_metrics AS (
    SELECT
        *,
        net_revenue / NULLIF(customer_tenure_days / 365.0, 0) as revenue_per_tenure
    FROM customer_metrics
),

-- Calculate overall medians for risk score
overall_medians AS (
    SELECT
        MEDIAN(avg_order_value) as median_aov,
        MEDIAN(order_frequency) as median_freq
    FROM customer_full_metrics
    WHERE avg_order_value IS NOT NULL
),

-- Calculate type medians for health index
type_medians AS (
    SELECT
        customer_type,
        MEDIAN(order_frequency) as type_median_freq,
        MEDIAN(net_revenue) as type_median_revenue
    FROM customer_full_metrics
    WHERE customer_type IS NOT NULL
    GROUP BY customer_type
),

-- Calculate overall median for net_revenue
overall_revenue_median AS (
    SELECT MEDIAN(net_revenue) as median_net_revenue
    FROM customer_full_metrics
    WHERE net_revenue IS NOT NULL
),

-- Calculate retention risk score
customer_risk_scores AS (
    SELECT
        cfm.*,
        om.median_aov,
        om.median_freq,
        tm.type_median_freq,
        orm.median_net_revenue,
        -- Retention risk score (0-100, higher = more risk)
        GREATEST(0, LEAST(100,
            (
                -- Recency risk (40%): days/90 capped at 1
                GREATEST(0, LEAST(1, COALESCE(cfm.days_since_last_order, 999) / 90.0)) * 0.40 +
                -- Frequency risk (25%): 1 - min(freq/median_freq, 2)/2 capped 0-1
                GREATEST(0, LEAST(1, 1 - LEAST(COALESCE(cfm.order_frequency, 0) / NULLIF(om.median_freq, 0), 2) / 2)) * 0.25 +
                -- Monetary risk (20%): 1 - min(aov/median_aov, 2)/2 capped 0-1
                GREATEST(0, LEAST(1, 1 - LEAST(COALESCE(cfm.avg_order_value, 0) / NULLIF(om.median_aov, 0), 2) / 2)) * 0.20 +
                -- Return risk (15%): return_rate/0.30 capped at 1
                GREATEST(0, LEAST(1, COALESCE(cfm.return_rate, 0) / 0.30)) * 0.15
            ) * 100
        )) as retention_risk_score
    FROM customer_full_metrics cfm
    CROSS JOIN overall_medians om
    LEFT JOIN type_medians tm ON cfm.customer_type = tm.customer_type
    CROSS JOIN overall_revenue_median orm
),

-- Add percentile rankings
customer_percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY days_since_last_order) as recency_percentile,
        PERCENT_RANK() OVER (ORDER BY order_frequency DESC) as frequency_percentile,
        PERCENT_RANK() OVER (ORDER BY avg_order_value DESC) as monetary_percentile,
        PERCENT_RANK() OVER (ORDER BY retention_risk_score) as risk_percentile
    FROM customer_risk_scores
),

-- Add customer type peer comparison
type_peer_metrics AS (
    SELECT
        customer_id,
        customer_type,
        DENSE_RANK() OVER (PARTITION BY customer_type ORDER BY retention_risk_score ASC) as type_rank,
        COUNT(*) OVER (PARTITION BY customer_type) as type_customer_count,
        AVG(order_frequency) OVER (PARTITION BY customer_type) as type_avg_frequency
    FROM customer_percentiles
    WHERE customer_type IS NOT NULL
)

SELECT
    cp.customer_id,
    cp.customer_type,
    cp.acquisition_source,
    cp.total_orders,
    cp.total_revenue,
    cp.first_order_date,
    cp.last_order_date,
    cp.days_since_last_order,
    cp.customer_tenure_days,
    cp.total_returns,
    cp.total_refund_amount,
    cp.avg_order_value,
    cp.order_frequency,
    cp.net_revenue,
    cp.return_rate,
    cp.revenue_per_tenure,
    cp.retention_risk_score,
    cp.recency_percentile,
    cp.frequency_percentile,
    cp.monetary_percentile,
    cp.risk_percentile,
    COALESCE(tpm.type_rank, 1) as type_rank,
    COALESCE(tpm.type_customer_count, 1) as type_customer_count,
    CASE
        WHEN COALESCE(cp.order_frequency, 0) > COALESCE(tpm.type_avg_frequency, 0) THEN 1
        ELSE 0
    END as above_type_avg_frequency,
    -- Waterfall tier classification
    CASE
        WHEN COALESCE(cp.days_since_last_order, 999) > 180 AND cp.total_orders = 1 THEN 'churned'
        WHEN COALESCE(cp.risk_percentile, 0.5) >= 0.85 AND COALESCE(cp.days_since_last_order, 999) > 90 THEN 'critical'
        WHEN COALESCE(cp.risk_percentile, 0.5) >= 0.70 OR (COALESCE(cp.days_since_last_order, 999) > 60 AND COALESCE(cp.return_rate, 0) >= 0.20) THEN 'at_risk'
        WHEN COALESCE(cp.risk_percentile, 0.5) >= 0.50 AND COALESCE(cp.order_frequency, 0) < 0.5 THEN 'needs_attention'
        WHEN COALESCE(cp.risk_percentile, 0.5) <= 0.20 AND COALESCE(cp.order_frequency, 0) >= 1.0 AND COALESCE(cp.return_rate, 0) < 0.10 THEN 'loyal'
        ELSE 'stable'
    END as retention_risk_tier,
    -- Customer health index (0-100, higher = healthier)
    GREATEST(0, LEAST(100,
        (
            -- Engagement factor (35%): 1 - days/90 capped 0-1
            GREATEST(0, LEAST(1, 1 - COALESCE(cp.days_since_last_order, 999) / 90.0)) * 0.35 +
            -- Loyalty factor (25%): min(freq/type_median_freq, 2)/2 capped 0-1
            GREATEST(0, LEAST(1, LEAST(COALESCE(cp.order_frequency, 0) / NULLIF(COALESCE(cp.type_median_freq, 1), 0), 2) / 2)) * 0.25 +
            -- Value factor (25%): min(net_revenue/median_net_revenue, 3)/3 capped 0-1
            GREATEST(0, LEAST(1, LEAST(COALESCE(cp.net_revenue, 0) / NULLIF(COALESCE(cp.median_net_revenue, 1), 0), 3) / 3)) * 0.25 +
            -- Quality factor (15%): 1 - return_rate/0.20 capped 0-1
            GREATEST(0, LEAST(1, 1 - COALESCE(cp.return_rate, 0) / 0.20)) * 0.15
        ) * 100
    )) as customer_health_index
FROM customer_percentiles cp
LEFT JOIN type_peer_metrics tpm ON cp.customer_id = tpm.customer_id
EOF
else
    # DuckDB version - uses date_diff with different argument order
    cat > "$MODEL_PATH" << 'EOF'
-- Customer Retention Risk Analysis Model with RFM Metrics
-- DuckDB-compatible SQL

-- Get reference date (latest order date in the system)
WITH reference_date AS (
    SELECT MAX(ordered_at) as max_order_date
    FROM main.int_sales__orders_enriched
),

-- Aggregate order metrics per customer
customer_orders AS (
    SELECT
        o.customer_id,
        COUNT(*) as total_orders,
        SUM(o.grand_total) as total_revenue,
        MIN(o.ordered_at) as first_order_date,
        MAX(o.ordered_at) as last_order_date
    FROM main.int_sales__orders_enriched o
    WHERE o.customer_id IS NOT NULL
      AND o.status != 'CANCELLED'
    GROUP BY o.customer_id
),

-- Aggregate return metrics per customer
customer_returns AS (
    SELECT
        r.customer_id,
        COUNT(*) as total_returns,
        SUM(r.REFUND_AMOUNT) as total_refund_amount
    FROM main.stg_orders__returns r
    WHERE r.customer_id IS NOT NULL
    GROUP BY r.customer_id
),

-- Join with customer master data
customer_base AS (
    SELECT
        c.customer_id,
        c.customer_type,
        c.acquisition_source,
        co.total_orders,
        co.total_revenue,
        co.first_order_date,
        co.last_order_date,
        date_diff('day', co.last_order_date, rd.max_order_date) as days_since_last_order,
        date_diff('day', co.first_order_date, rd.max_order_date) as customer_tenure_days,
        COALESCE(cr.total_returns, 0) as total_returns,
        COALESCE(cr.total_refund_amount, 0) as total_refund_amount
    FROM main.stg_customer__customers c
    INNER JOIN customer_orders co ON c.customer_id = co.customer_id
    LEFT JOIN customer_returns cr ON c.customer_id = cr.customer_id
    CROSS JOIN reference_date rd
),

-- Calculate derived metrics
customer_metrics AS (
    SELECT
        *,
        total_revenue / NULLIF(total_orders, 0) as avg_order_value,
        total_orders / NULLIF(customer_tenure_days / 30.0, 0) as order_frequency,
        total_revenue - total_refund_amount as net_revenue,
        total_returns / NULLIF(total_orders, 0) as return_rate
    FROM customer_base
),

-- Add annualized revenue
customer_full_metrics AS (
    SELECT
        *,
        net_revenue / NULLIF(customer_tenure_days / 365.0, 0) as revenue_per_tenure
    FROM customer_metrics
),

-- Calculate overall medians for risk score (DuckDB doesn't support window PERCENTILE_CONT)
overall_medians AS (
    SELECT
        MEDIAN(avg_order_value) as median_aov,
        MEDIAN(order_frequency) as median_freq
    FROM customer_full_metrics
    WHERE avg_order_value IS NOT NULL
),

-- Calculate type medians for health index
type_medians AS (
    SELECT
        customer_type,
        MEDIAN(order_frequency) as type_median_freq,
        MEDIAN(net_revenue) as type_median_revenue
    FROM customer_full_metrics
    WHERE customer_type IS NOT NULL
    GROUP BY customer_type
),

-- Calculate overall median for net_revenue
overall_revenue_median AS (
    SELECT MEDIAN(net_revenue) as median_net_revenue
    FROM customer_full_metrics
    WHERE net_revenue IS NOT NULL
),

-- Calculate retention risk score
customer_risk_scores AS (
    SELECT
        cfm.*,
        om.median_aov,
        om.median_freq,
        tm.type_median_freq,
        orm.median_net_revenue,
        -- Retention risk score (0-100, higher = more risk)
        GREATEST(0, LEAST(100,
            (
                -- Recency risk (40%): days/90 capped at 1
                GREATEST(0, LEAST(1, COALESCE(cfm.days_since_last_order, 999) / 90.0)) * 0.40 +
                -- Frequency risk (25%): 1 - min(freq/median_freq, 2)/2 capped 0-1
                GREATEST(0, LEAST(1, 1 - LEAST(COALESCE(cfm.order_frequency, 0) / NULLIF(om.median_freq, 0), 2) / 2)) * 0.25 +
                -- Monetary risk (20%): 1 - min(aov/median_aov, 2)/2 capped 0-1
                GREATEST(0, LEAST(1, 1 - LEAST(COALESCE(cfm.avg_order_value, 0) / NULLIF(om.median_aov, 0), 2) / 2)) * 0.20 +
                -- Return risk (15%): return_rate/0.30 capped at 1
                GREATEST(0, LEAST(1, COALESCE(cfm.return_rate, 0) / 0.30)) * 0.15
            ) * 100
        )) as retention_risk_score
    FROM customer_full_metrics cfm
    CROSS JOIN overall_medians om
    LEFT JOIN type_medians tm ON cfm.customer_type = tm.customer_type
    CROSS JOIN overall_revenue_median orm
),

-- Add percentile rankings
customer_percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY days_since_last_order) as recency_percentile,
        PERCENT_RANK() OVER (ORDER BY order_frequency DESC) as frequency_percentile,
        PERCENT_RANK() OVER (ORDER BY avg_order_value DESC) as monetary_percentile,
        PERCENT_RANK() OVER (ORDER BY retention_risk_score) as risk_percentile
    FROM customer_risk_scores
),

-- Add customer type peer comparison
type_peer_metrics AS (
    SELECT
        customer_id,
        customer_type,
        DENSE_RANK() OVER (PARTITION BY customer_type ORDER BY retention_risk_score ASC) as type_rank,
        COUNT(*) OVER (PARTITION BY customer_type) as type_customer_count,
        AVG(order_frequency) OVER (PARTITION BY customer_type) as type_avg_frequency
    FROM customer_percentiles
    WHERE customer_type IS NOT NULL
)

SELECT
    cp.customer_id,
    cp.customer_type,
    cp.acquisition_source,
    cp.total_orders,
    cp.total_revenue,
    cp.first_order_date,
    cp.last_order_date,
    cp.days_since_last_order,
    cp.customer_tenure_days,
    cp.total_returns,
    cp.total_refund_amount,
    cp.avg_order_value,
    cp.order_frequency,
    cp.net_revenue,
    cp.return_rate,
    cp.revenue_per_tenure,
    cp.retention_risk_score,
    cp.recency_percentile,
    cp.frequency_percentile,
    cp.monetary_percentile,
    cp.risk_percentile,
    COALESCE(tpm.type_rank, 1) as type_rank,
    COALESCE(tpm.type_customer_count, 1) as type_customer_count,
    CASE
        WHEN COALESCE(cp.order_frequency, 0) > COALESCE(tpm.type_avg_frequency, 0) THEN 1
        ELSE 0
    END as above_type_avg_frequency,
    -- Waterfall tier classification
    CASE
        WHEN COALESCE(cp.days_since_last_order, 999) > 180 AND cp.total_orders = 1 THEN 'churned'
        WHEN COALESCE(cp.risk_percentile, 0.5) >= 0.85 AND COALESCE(cp.days_since_last_order, 999) > 90 THEN 'critical'
        WHEN COALESCE(cp.risk_percentile, 0.5) >= 0.70 OR (COALESCE(cp.days_since_last_order, 999) > 60 AND COALESCE(cp.return_rate, 0) >= 0.20) THEN 'at_risk'
        WHEN COALESCE(cp.risk_percentile, 0.5) >= 0.50 AND COALESCE(cp.order_frequency, 0) < 0.5 THEN 'needs_attention'
        WHEN COALESCE(cp.risk_percentile, 0.5) <= 0.20 AND COALESCE(cp.order_frequency, 0) >= 1.0 AND COALESCE(cp.return_rate, 0) < 0.10 THEN 'loyal'
        ELSE 'stable'
    END as retention_risk_tier,
    -- Customer health index (0-100, higher = healthier)
    GREATEST(0, LEAST(100,
        (
            -- Engagement factor (35%): 1 - days/90 capped 0-1
            GREATEST(0, LEAST(1, 1 - COALESCE(cp.days_since_last_order, 999) / 90.0)) * 0.35 +
            -- Loyalty factor (25%): min(freq/type_median_freq, 2)/2 capped 0-1
            GREATEST(0, LEAST(1, LEAST(COALESCE(cp.order_frequency, 0) / NULLIF(COALESCE(cp.type_median_freq, 1), 0), 2) / 2)) * 0.25 +
            -- Value factor (25%): min(net_revenue/median_net_revenue, 3)/3 capped 0-1
            GREATEST(0, LEAST(1, LEAST(COALESCE(cp.net_revenue, 0) / NULLIF(COALESCE(cp.median_net_revenue, 1), 0), 3) / 3)) * 0.25 +
            -- Quality factor (15%): 1 - return_rate/0.20 capped 0-1
            GREATEST(0, LEAST(1, 1 - COALESCE(cp.return_rate, 0) / 0.20)) * 0.15
        ) * 100
    )) as customer_health_index
FROM customer_percentiles cp
LEFT JOIN type_peer_metrics tpm ON cp.customer_id = tpm.customer_id
EOF
fi

# Run dbt
cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

echo "Installing dbt dependencies..."
dbt deps

echo "Building rpt_customer_retention_risk..."
dbt run -s rpt_customer_retention_risk
