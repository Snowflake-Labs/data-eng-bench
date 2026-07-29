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

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Create necessary directories
mkdir -p models/staging/customer
mkdir -p models/intermediate/customer
mkdir -p models/marts/customer
mkdir -p macros

cat > macros/calculate_journey_velocity.sql << 'EOF'
{% macro calculate_journey_velocity(total_events, days_since_first, orders_count) %}
    LEAST(100, GREATEST(0,
        (LEAST(1, ({{ total_events }} / NULLIF({{ days_since_first }} / 30.0, 0)) / 10.0) * 0.40 +
         LEAST(1, {{ orders_count }} / 10.0) * 0.35 +
         (1 - LEAST(1, {{ days_since_first }} / 365.0)) * 0.25) * 100
    ))
{% endmacro %}
EOF

cat > models/staging/customer/stg_customer__lifecycle_events.sql << 'EOF'
WITH reference AS (
    SELECT MAX(EVENT_DATE) as reference_date
    FROM {% if target.type == 'snowflake' %}CUSTOMER.CUSTOMER_LIFECYCLE_EVENTS{% else %}main.CUSTOMER_LIFECYCLE_EVENTS{% endif %}
),
events AS (
    SELECT
        CUSTOMER_ID,
        MIN(EVENT_DATE) as first_event_date,
        MAX(EVENT_DATE) as last_event_date,
        COUNT(*) as total_lifecycle_events,
        MIN(CASE WHEN EVENT_TYPE IN ('ACTIVATED', 'FIRST_PURCHASE') THEN EVENT_DATE END) as activation_date,
        COUNT(CASE WHEN EVENT_TYPE = 'REACTIVATED' THEN 1 END) as reactivation_count
    FROM {% if target.type == 'snowflake' %}CUSTOMER.CUSTOMER_LIFECYCLE_EVENTS{% else %}main.CUSTOMER_LIFECYCLE_EVENTS{% endif %}
    GROUP BY CUSTOMER_ID
),
current_segments AS (
    SELECT
        csm.CUSTOMER_ID,
        cs.SEGMENT_NAME as current_segment,
        ROW_NUMBER() OVER (PARTITION BY csm.CUSTOMER_ID ORDER BY csm.ADDED_DATE DESC, csm.MEMBERSHIP_ID) as rn
    FROM {% if target.type == 'snowflake' %}CUSTOMER.CUSTOMER_SEGMENT_MEMBERS{% else %}main.CUSTOMER_SEGMENT_MEMBERS{% endif %} csm
    INNER JOIN {% if target.type == 'snowflake' %}CUSTOMER.CUSTOMER_SEGMENTS{% else %}main.CUSTOMER_SEGMENTS{% endif %} cs ON csm.SEGMENT_ID = cs.SEGMENT_ID
    WHERE csm.IS_ACTIVE = true
)
SELECT
    e.CUSTOMER_ID as customer_id,
    e.first_event_date,
    e.last_event_date,
    e.total_lifecycle_events,
    e.activation_date,
    e.reactivation_count,
    DATEDIFF('day', e.activation_date, r.reference_date) as days_since_activation,
    DATEDIFF('day', e.last_event_date, r.reference_date) as days_since_last_event,
    cs.current_segment,
    CASE
        WHEN e.activation_date IS NULL THEN 'NEW'
        WHEN DATEDIFF('day', e.last_event_date, r.reference_date) > 90 THEN 'DORMANT'
        WHEN DATEDIFF('day', e.last_event_date, r.reference_date) > 30 THEN 'AT_RISK'
        WHEN e.total_lifecycle_events >= 3 THEN 'ACTIVE'
        ELSE 'ACTIVATED'
    END as lifecycle_stage,
    r.reference_date
FROM events e
CROSS JOIN reference r
LEFT JOIN current_segments cs ON e.CUSTOMER_ID = cs.CUSTOMER_ID AND cs.rn = 1
EOF

cat > models/intermediate/customer/int_customer__journey_metrics.sql << 'EOF'
WITH base AS (
    SELECT * FROM {{ ref('stg_customer__lifecycle_events') }}
),
order_metrics AS (
    SELECT
        customer_id,
        COUNT(*) as orders_count,
        SUM(grand_total) as total_order_value,
        MAX(ordered_at) as last_order_date
    FROM {{ ref('int_sales__orders_enriched') }}
    WHERE is_delivered = true
    GROUP BY customer_id
)
SELECT
    b.*,
    DATEDIFF('day', b.first_event_date, COALESCE(b.activation_date, b.reference_date)) as time_to_activate,
    b.total_lifecycle_events / NULLIF(DATEDIFF('day', b.first_event_date, b.reference_date) / 30.0, 0) as events_per_month,
    COALESCE(o.orders_count, 0) as orders_count,
    COALESCE(o.total_order_value, 0) as total_order_value,
    {{ calculate_journey_velocity('total_lifecycle_events', 'DATEDIFF(\'day\', first_event_date, reference_date)', 'COALESCE(o.orders_count, 0)') }} as journey_velocity_score,
    LEAST(1, GREATEST(0, b.total_lifecycle_events / NULLIF(DATEDIFF('day', b.first_event_date, b.reference_date) / 30.0, 0) / 2.0)) as engagement_consistency,
    NULLIF(DATEDIFF('day', b.first_event_date, b.last_event_date), 0) / NULLIF(b.total_lifecycle_events - 1, 0) as avg_days_between_events,
    CASE WHEN b.activation_date IS NOT NULL THEN 1 ELSE 0 END as activation_rate,
    o.last_order_date
FROM base b
LEFT JOIN order_metrics o ON b.customer_id = o.customer_id
EOF

cat > models/marts/customer/mart_customer__lifecycle_scorecard.sql << 'EOF'
WITH metrics AS (
    SELECT * FROM {{ ref('int_customer__journey_metrics') }}
),
percentiles AS (
    SELECT
        *,
        PERCENT_RANK() OVER (ORDER BY journey_velocity_score ASC) as velocity_percentile,
        PERCENT_RANK() OVER (ORDER BY events_per_month ASC) as engagement_percentile,
        PERCENT_RANK() OVER (ORDER BY total_order_value ASC) as value_percentile,
        PERCENT_RANK() OVER (ORDER BY COALESCE(engagement_consistency, 0) ASC) as consistency_percentile
    FROM metrics
),
scores AS (
    SELECT
        *,
        LEAST(100, GREATEST(0,
            (journey_velocity_score / 100.0 * 0.30 +
             LEAST(1, orders_count / 10.0) * 0.25 +
             COALESCE(engagement_consistency, 0) * 0.25 +
             (1 - LEAST(1, reactivation_count / 5.0)) * 0.20) * 100
        )) as customer_lifecycle_index,
        LEAST(100, GREATEST(0,
            (LEAST(1, COALESCE(days_since_last_event, 999) / 180.0) * 0.40 +
             (1 - velocity_percentile) * 0.30 +
             LEAST(1, reactivation_count / 3.0) * 0.20 +
             LEAST(1, COALESCE(DATEDIFF('day', last_order_date, reference_date), 999) / 180.0) * 0.10) * 100
        )) as churn_risk_score,
        CASE
            WHEN COALESCE(velocity_percentile, 0) >= 0.80 AND COALESCE(orders_count, 0) >= 4 AND COALESCE(days_since_activation, 999) < 120 AND COALESCE(engagement_consistency, 0) > 0.5 THEN 'thriving'
            WHEN COALESCE(velocity_percentile, 0) >= 0.60 AND (COALESCE(orders_count, 0) >= 2 OR COALESCE(events_per_month, 0) >= 2.0) THEN 'growing'
            WHEN COALESCE(velocity_percentile, 0) >= 0.40 OR (COALESCE(orders_count, 0) >= 1 AND COALESCE(days_since_last_event, 999) < 60) THEN 'stable'
            WHEN COALESCE(days_since_last_event, 999) > 45 AND COALESCE(velocity_percentile, 0) < 0.30 THEN 'at_risk'
            ELSE 'dormant'
        END as lifecycle_health_tier
    FROM percentiles
),
peers AS (
    SELECT
        s.*,
        RANK() OVER (PARTITION BY current_segment ORDER BY journey_velocity_score DESC, customer_id) as segment_velocity_rank,
        COUNT(*) OVER (PARTITION BY current_segment) as segment_peer_count,
        AVG(journey_velocity_score) OVER (PARTITION BY current_segment) as segment_avg_velocity,
        PERCENT_RANK() OVER (PARTITION BY current_segment ORDER BY journey_velocity_score ASC) as segment_percentile
    FROM scores s
)
SELECT
    customer_id, first_event_date, last_event_date, total_lifecycle_events,
    activation_date, reactivation_count, days_since_activation, days_since_last_event,
    current_segment, lifecycle_stage,
    time_to_activate, events_per_month, orders_count, total_order_value,
    journey_velocity_score, engagement_consistency, avg_days_between_events, activation_rate,
    velocity_percentile, engagement_percentile, value_percentile, consistency_percentile,
    lifecycle_health_tier, customer_lifecycle_index, churn_risk_score,
    segment_velocity_rank, segment_peer_count,
    CASE WHEN journey_velocity_score > segment_avg_velocity THEN 1 ELSE 0 END as above_segment_avg_velocity,
    segment_percentile
FROM peers
EOF

dbt deps
dbt run -s stg_customer__lifecycle_events int_customer__journey_metrics mart_customer__lifecycle_scorecard
