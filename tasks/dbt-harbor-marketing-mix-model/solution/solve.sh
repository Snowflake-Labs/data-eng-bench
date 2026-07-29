#!/bin/bash
set -euo pipefail

echo "========================================="
echo "Marketing Mix Modeling (MMM) Solution"
echo "========================================="

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

# For Snowflake, override generate_schema_name to flatten all schemas to 'main'
if [ "$DB_TYPE" = "snowflake" ]; then
    mkdir -p "$DBT_PROJECT_DIR/macros/utils"
    cat > "$DBT_PROJECT_DIR/macros/utils/generate_schema_name.sql" << 'SCHEMAEOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
{{ target.schema }}
{%- endmacro %}
SCHEMAEOF
fi

cd "$DBT_PROJECT_DIR"

echo ""
echo "Step 1: Creating model directories..."
echo "-------------------------------------"
mkdir -p models/staging/mmm
mkdir -p models/intermediate/mmm
mkdir -p models/marts/mmm
mkdir -p macros

echo ""
echo "Step 2: Creating sources.yml..."
echo "-------------------------------------"
# Sources only needed for DuckDB (Snowflake uses ref() to pre-built staging models)
cat > models/staging/mmm/sources.yml <<'YML'
version: 2

sources:
  - name: raw
    description: Raw retail database tables
    database: "{{ 'retail' if target.type == 'duckdb' else target.database }}"
    schema: main
    tables:
      - name: FACT_SALES
      - name: FACT_MARKETING_SPEND
      - name: DIM_DATE
      - name: DIM_CHANNEL
      - name: CAMPAIGN_CHANNELS
YML

echo ""
echo "========================================="
echo "Creating 15 dbt models for MMM analysis"
echo "========================================="

echo ""
echo "STAGING LAYER (4 models)"
echo "-------------------------------------"

# Model 1: stg_mmm__daily_sales
echo "Creating stg_mmm__daily_sales..."
cat > models/staging/mmm/stg_mmm__daily_sales.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='staging'
    )
}}

{% if target.type == 'snowflake' %}

WITH sales_data AS (
    SELECT
        d.FULL_DATE AS metric_date,
        COALESCE(c.CHANNEL_NAME, 'Unknown') AS channel_name,
        SUM(s.TOTAL_AMOUNT) AS total_revenue,
        COUNT(DISTINCT s.ORDER_ID) AS order_count,
        SUM(s.QUANTITY) AS units_sold
    FROM {{ ref('stg_analytics__fact_sales') }} s
    JOIN {{ ref('stg_analytics__dim_date') }} d ON s.DATE_KEY = d.DATE_KEY
    LEFT JOIN {{ ref('stg_analytics__dim_channel') }} c ON s.CHANNEL_KEY = c.CHANNEL_KEY
    GROUP BY d.FULL_DATE, c.CHANNEL_NAME
)

SELECT
    metric_date,
    channel_name AS channel_id,
    channel_name,
    total_revenue,
    order_count,
    units_sold
FROM sales_data
ORDER BY metric_date, channel_id

{% else %}

WITH sales_data AS (
    SELECT
        d.FULL_DATE AS metric_date,
        COALESCE(s.CHANNEL_KEY, 0) AS channel_id,
        COALESCE(c.CHANNEL_NAME, 'Unknown') AS channel_name,
        SUM(s.TOTAL_AMOUNT) AS total_revenue,
        COUNT(DISTINCT s.ORDER_ID) AS order_count,
        SUM(s.QUANTITY) AS units_sold
    FROM {{ source('raw', 'FACT_SALES') }} s
    JOIN {{ source('raw', 'DIM_DATE') }} d ON s.DATE_KEY = d.DATE_KEY
    LEFT JOIN {{ source('raw', 'DIM_CHANNEL') }} c ON s.CHANNEL_KEY = c.CHANNEL_KEY
    GROUP BY d.FULL_DATE, s.CHANNEL_KEY, c.CHANNEL_NAME
)

SELECT
    metric_date,
    channel_name AS channel_id,
    channel_name,
    total_revenue,
    order_count,
    units_sold
FROM sales_data
ORDER BY metric_date, channel_id

{% endif %}
SQL

# Model 2: stg_mmm__marketing_spend
echo "Creating stg_mmm__marketing_spend..."
cat > models/staging/mmm/stg_mmm__marketing_spend.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='staging'
    )
}}

{% if target.type == 'snowflake' %}

WITH marketing_raw AS (
    SELECT
        d.FULL_DATE AS metric_date,
        COALESCE(c.CHANNEL_NAME, 'Unknown') AS source_channel,
        m.SPEND_AMOUNT,
        m.IMPRESSIONS,
        m.CLICKS
    FROM {{ ref('stg_fact_marketing_spend') }} m
    JOIN {{ ref('stg_analytics__dim_date') }} d ON m.DATE_KEY = d.DATE_KEY
    LEFT JOIN {{ ref('stg_analytics__dim_channel') }} c ON m.CHANNEL_KEY = c.CHANNEL_KEY
),

channel_mapping AS (
    SELECT
        metric_date,
        CASE
            WHEN LOWER(source_channel) LIKE '%email%' THEN 'Email'
            WHEN LOWER(source_channel) LIKE '%google%' OR LOWER(source_channel) LIKE '%search%' THEN 'Paid Search'
            WHEN LOWER(source_channel) LIKE '%facebook%' OR LOWER(source_channel) LIKE '%instagram%'
                 OR LOWER(source_channel) LIKE '%social%' OR LOWER(source_channel) LIKE '%twitter%'
                 OR LOWER(source_channel) LIKE '%linkedin%' THEN 'Social Media'
            WHEN LOWER(source_channel) LIKE '%display%' THEN 'Display Ads'
            WHEN LOWER(source_channel) LIKE '%tv%' OR LOWER(source_channel) LIKE '%video%' THEN 'TV/Video'
            WHEN LOWER(source_channel) LIKE '%sms%' THEN 'Social Media'
            ELSE 'Display Ads'
        END AS channel_name,
        SPEND_AMOUNT,
        IMPRESSIONS,
        CLICKS
    FROM marketing_raw
),

aggregated AS (
    SELECT
        metric_date,
        channel_name,
        SUM(SPEND_AMOUNT) AS spend_amount,
        SUM(IMPRESSIONS) AS impressions,
        SUM(CLICKS) AS clicks
    FROM channel_mapping
    GROUP BY metric_date, channel_name
)

SELECT
    metric_date,
    channel_name AS channel_id,
    channel_name,
    spend_amount,
    impressions,
    clicks
FROM aggregated
ORDER BY metric_date, channel_name

{% else %}

WITH marketing_raw AS (
    SELECT
        d.FULL_DATE AS metric_date,
        cc.CHANNEL_TYPE AS source_channel,
        m.SPEND_AMOUNT,
        m.IMPRESSIONS,
        m.CLICKS
    FROM {{ source('raw', 'FACT_MARKETING_SPEND') }} m
    JOIN {{ source('raw', 'CAMPAIGN_CHANNELS') }} cc ON m.CAMPAIGN_ID = cc.CAMPAIGN_ID
    JOIN {{ source('raw', 'DIM_DATE') }} d ON m.DATE_KEY = d.DATE_KEY
),

channel_mapping AS (
    SELECT
        metric_date,
        CASE
            WHEN LOWER(source_channel) LIKE '%email%' THEN 'Email'
            WHEN LOWER(source_channel) LIKE '%google%' OR LOWER(source_channel) LIKE '%search%' THEN 'Paid Search'
            WHEN LOWER(source_channel) LIKE '%facebook%' OR LOWER(source_channel) LIKE '%instagram%'
                 OR LOWER(source_channel) LIKE '%social%' OR LOWER(source_channel) LIKE '%twitter%'
                 OR LOWER(source_channel) LIKE '%linkedin%' THEN 'Social Media'
            WHEN LOWER(source_channel) LIKE '%display%' THEN 'Display Ads'
            WHEN LOWER(source_channel) LIKE '%tv%' OR LOWER(source_channel) LIKE '%video%' THEN 'TV/Video'
            WHEN LOWER(source_channel) LIKE '%sms%' THEN 'Social Media'
            ELSE 'Display Ads'
        END AS channel_name,
        SPEND_AMOUNT,
        IMPRESSIONS,
        CLICKS
    FROM marketing_raw
),

aggregated AS (
    SELECT
        metric_date,
        channel_name,
        SUM(SPEND_AMOUNT) AS spend_amount,
        SUM(IMPRESSIONS) AS impressions,
        SUM(CLICKS) AS clicks
    FROM channel_mapping
    GROUP BY metric_date, channel_name
)

SELECT
    metric_date,
    channel_name AS channel_id,
    channel_name,
    spend_amount,
    impressions,
    clicks
FROM aggregated
ORDER BY metric_date, channel_name

{% endif %}
SQL

# Model 3: stg_mmm__calendar
echo "Creating stg_mmm__calendar..."
cat > models/staging/mmm/stg_mmm__calendar.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='staging'
    )
}}

{% if target.type == 'snowflake' %}

SELECT
    FULL_DATE AS metric_date,
    DAY_OF_WEEK AS day_of_week,
    DAY_NAME AS day_name,
    MONTH_NUMBER AS month,
    QUARTER AS quarter,
    CASE WHEN UPPER(CAST(IS_WEEKEND AS VARCHAR)) IN ('1','TRUE','T','YES','Y') THEN 1 ELSE 0 END AS is_weekend,
    CASE WHEN UPPER(CAST(IS_HOLIDAY AS VARCHAR)) IN ('1','TRUE','T','YES','Y') THEN 1 ELSE 0 END AS is_holiday,
    CASE
        WHEN UPPER(CAST(IS_HOLIDAY AS VARCHAR)) IN ('1','TRUE','T','YES','Y') THEN DAY_NAME
        ELSE NULL
    END AS holiday_name
FROM {{ ref('stg_analytics__dim_date') }}
ORDER BY metric_date

{% else %}

SELECT
    FULL_DATE AS metric_date,
    DAY_OF_WEEK AS day_of_week,
    DAY_NAME AS day_name,
    MONTH_NUMBER AS month,
    QUARTER AS quarter,
    CASE WHEN IS_WEEKEND = 1 THEN 1 ELSE 0 END AS is_weekend,
    CASE WHEN IS_HOLIDAY = 1 THEN 1 ELSE 0 END AS is_holiday,
    CASE
        WHEN IS_HOLIDAY = 1 THEN DAY_NAME
        ELSE NULL
    END AS holiday_name
FROM {{ source('raw', 'DIM_DATE') }}
ORDER BY metric_date

{% endif %}
SQL

# Model 4: stg_mmm__channel_mapping (hardcoded, no source dependency)
echo "Creating stg_mmm__channel_mapping..."
cat > models/staging/mmm/stg_mmm__channel_mapping.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='staging'
    )
}}

WITH channel_params AS (
    SELECT 'Display Ads' AS channel_name, 'DISPLAY' AS channel_type, 0.3 AS decay_rate, 15000.0 AS saturation_halfpoint, 1.5 AS saturation_alpha, 2.8 AS channel_coefficient
    UNION ALL
    SELECT 'Email' AS channel_name, 'EMAIL' AS channel_type, 0.5 AS decay_rate, 80000.0 AS saturation_halfpoint, 2.0 AS saturation_alpha, 4.5 AS channel_coefficient
    UNION ALL
    SELECT 'TV/Video' AS channel_name, 'VIDEO' AS channel_type, 0.7 AS decay_rate, 60000.0 AS saturation_halfpoint, 1.8 AS saturation_alpha, 2.5 AS channel_coefficient
    UNION ALL
    SELECT 'Paid Search' AS channel_name, 'SEARCH' AS channel_type, 0.1 AS decay_rate, 20000.0 AS saturation_halfpoint, 1.6 AS saturation_alpha, 3.8 AS channel_coefficient
    UNION ALL
    SELECT 'Social Media' AS channel_name, 'SOCIAL' AS channel_type, 0.5 AS decay_rate, 40000.0 AS saturation_halfpoint, 1.4 AS saturation_alpha, 3.2 AS channel_coefficient
)

SELECT
    channel_name AS channel_id,
    channel_name,
    channel_type,
    decay_rate,
    saturation_halfpoint,
    saturation_halfpoint / 30.0 AS saturation_halfpoint_daily,
    saturation_alpha,
    saturation_alpha AS saturation_shape,
    channel_coefficient
FROM channel_params
ORDER BY channel_name
SQL

echo ""
echo "INTERMEDIATE LAYER (5 models)"
echo "-------------------------------------"

# Model 5: int_mmm__baseline_sales
echo "Creating int_mmm__baseline_sales..."
cat > models/intermediate/mmm/int_mmm__baseline_sales.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='intermediate'
    )
}}

WITH daily_sales AS (
    SELECT
        metric_date,
        SUM(total_revenue) AS actual_sales
    FROM {{ ref('stg_mmm__daily_sales') }}
    GROUP BY metric_date
),

daily_spend AS (
    SELECT
        metric_date,
        SUM(spend_amount) AS daily_spend
    FROM {{ ref('stg_mmm__marketing_spend') }}
    GROUP BY metric_date
),

date_bounds AS (
    SELECT
        GREATEST(MIN(s.metric_date), MIN(m.metric_date)) AS min_date,
        LEAST(MAX(s.metric_date), MAX(m.metric_date)) AS max_date
    FROM daily_sales s
    CROSS JOIN daily_spend m
),

calendar AS (
    SELECT c.*
    FROM {{ ref('stg_mmm__calendar') }} c
    CROSS JOIN date_bounds b
    WHERE c.metric_date BETWEEN b.min_date AND b.max_date
),

baseline_estimate AS (
    SELECT AVG(s.actual_sales) AS base_daily_revenue
    FROM daily_sales s
    LEFT JOIN daily_spend d ON s.metric_date = d.metric_date
    WHERE COALESCE(d.daily_spend, 0) < 5000
),

start_date AS (
    SELECT MIN(metric_date) AS min_date
    FROM calendar
),

joined AS (
    SELECT
        c.metric_date,
        c.day_of_week,
        c.month,
        c.is_weekend,
        c.is_holiday,
        b.base_daily_revenue,
        s.actual_sales,
        DATEDIFF('month', sd.min_date, c.metric_date) AS months_since_start
    FROM calendar c
    LEFT JOIN daily_sales s ON c.metric_date = s.metric_date
    CROSS JOIN baseline_estimate b
    CROSS JOIN start_date sd
),

baseline_raw AS (
    SELECT
        metric_date,
        CASE day_of_week
            WHEN 1 THEN 0.85
            WHEN 2 THEN 1.0
            WHEN 3 THEN 1.0
            WHEN 4 THEN 1.0
            WHEN 5 THEN 1.05
            WHEN 6 THEN 0.95
            WHEN 7 THEN 0.95
            ELSE 1.0
        END AS day_of_week_factor,
        CASE month
            WHEN 1 THEN 0.90
            WHEN 2 THEN 0.92
            WHEN 3 THEN 0.95
            WHEN 4 THEN 0.98
            WHEN 5 THEN 1.00
            WHEN 6 THEN 1.02
            WHEN 7 THEN 1.03
            WHEN 8 THEN 1.02
            WHEN 9 THEN 1.00
            WHEN 10 THEN 1.03
            WHEN 11 THEN 1.05
            WHEN 12 THEN 1.20
            ELSE 1.0
        END AS month_factor,
        CASE WHEN is_holiday = 1 THEN 1.15 ELSE 1.0 END AS holiday_lift_factor,
        POWER(1.02, months_since_start) AS baseline_trend,
        is_weekend,
        is_holiday,
        base_daily_revenue,
        actual_sales
    FROM joined
),

scaled AS (
    SELECT
        b.*,
        base_daily_revenue * baseline_trend * day_of_week_factor * month_factor * holiday_lift_factor AS baseline_revenue_raw
    FROM baseline_raw b
),

scale_factor AS (
    SELECT
        CASE
            WHEN AVG(baseline_revenue_raw) > 0 THEN (0.18 * AVG(actual_sales)) / AVG(baseline_revenue_raw)
            ELSE 1.0
        END AS scale
    FROM scaled
)

SELECT
    s.metric_date,
    s.baseline_revenue_raw * f.scale AS baseline_revenue,
    s.baseline_trend,
    s.day_of_week_factor,
    s.month_factor,
    s.holiday_lift_factor,
    s.is_weekend,
    s.is_holiday
FROM scaled s
CROSS JOIN scale_factor f
SQL

# Model 6: int_mmm__adstock_transformed
echo "Creating int_mmm__adstock_transformed..."
cat > models/intermediate/mmm/int_mmm__adstock_transformed.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='intermediate'
    )
}}

WITH marketing_with_params AS (
    SELECT
        m.metric_date,
        m.channel_name,
        m.spend_amount as raw_spend,
        cm.decay_rate,
        ROW_NUMBER() OVER (PARTITION BY m.channel_name ORDER BY m.metric_date) as row_num
    FROM {{ ref('stg_mmm__marketing_spend') }} m
    JOIN {{ ref('stg_mmm__channel_mapping') }} cm ON m.channel_name = cm.channel_name
    WHERE m.metric_date >= (SELECT MIN(metric_date) FROM {{ ref('stg_mmm__daily_sales') }})
      AND m.metric_date <= (SELECT MAX(metric_date) FROM {{ ref('stg_mmm__daily_sales') }})
),

date_sequence AS (
    SELECT
        metric_date,
        channel_name,
        raw_spend,
        decay_rate,
        row_num
    FROM marketing_with_params
),

adstock_calc AS (
    SELECT
        curr.metric_date,
        curr.channel_name,
        curr.raw_spend,
        curr.decay_rate,
        curr.raw_spend + COALESCE(
            SUM(
                CASE WHEN prev.metric_date < curr.metric_date
                     AND DATEDIFF('day', prev.metric_date, curr.metric_date) <= 90
                     THEN prev.raw_spend * POWER(curr.decay_rate, DATEDIFF('day', prev.metric_date, curr.metric_date))
                     ELSE 0
                END
            ),
            0
        ) as adstock_spend
    FROM date_sequence curr
    LEFT JOIN date_sequence prev
        ON curr.channel_name = prev.channel_name
        AND prev.metric_date < curr.metric_date
        AND DATEDIFF('day', prev.metric_date, curr.metric_date) <= 90
    GROUP BY curr.metric_date, curr.channel_name, curr.raw_spend, curr.decay_rate
),

with_windows AS (
    SELECT
        metric_date,
        channel_name,
        raw_spend,
        decay_rate,
        adstock_spend,
        SUM(adstock_spend) OVER (
            PARTITION BY channel_name
            ORDER BY metric_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) as cumulative_adstock_7d,
        SUM(adstock_spend) OVER (
            PARTITION BY channel_name
            ORDER BY metric_date
            ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
        ) as cumulative_adstock_30d
    FROM adstock_calc
)

SELECT
    metric_date,
    ROW_NUMBER() OVER (ORDER BY channel_name) as channel_id,
    channel_name,
    raw_spend,
    decay_rate,
    adstock_spend,
    cumulative_adstock_7d,
    cumulative_adstock_30d
FROM with_windows
ORDER BY metric_date, channel_name

SQL

# Model 7: int_mmm__saturation_curves
echo "Creating int_mmm__saturation_curves..."
cat > models/intermediate/mmm/int_mmm__saturation_curves.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='intermediate'
    )
}}

WITH adstock_with_params AS (
    SELECT
        a.metric_date,
        a.channel_id,
        a.channel_name,
        a.raw_spend,
        a.adstock_spend,
        cm.saturation_halfpoint_daily,
        cm.saturation_alpha
    FROM {{ ref('int_mmm__adstock_transformed') }} a
    JOIN {{ ref('stg_mmm__channel_mapping') }} cm ON a.channel_name = cm.channel_name
),

saturation_applied AS (
    SELECT
        metric_date,
        channel_id,
        channel_name,
        raw_spend,
        adstock_spend,
        saturation_halfpoint_daily,
        saturation_alpha,
        CASE
            WHEN adstock_spend > 0 THEN
                (POWER(adstock_spend, saturation_alpha) /
                 (POWER(adstock_spend, saturation_alpha) + POWER(saturation_halfpoint_daily, saturation_alpha))) * adstock_spend
            ELSE 0
        END as saturated_spend
    FROM adstock_with_params
),

with_metrics AS (
    SELECT
        metric_date,
        channel_id,
        channel_name,
        raw_spend,
        adstock_spend,
        saturation_halfpoint_daily,
        saturation_alpha,
        saturated_spend,
        CASE
            WHEN adstock_spend > 0 THEN
                LEAST(100.0, GREATEST(0.0, 100.0 * saturated_spend / adstock_spend))
            ELSE 0
        END as saturation_efficiency_pct,
        CASE
            WHEN saturation_halfpoint_daily > 0 THEN
                adstock_spend / saturation_halfpoint_daily
            ELSE 0
        END as spend_ratio
    FROM saturation_applied
)

SELECT
    metric_date,
    channel_id,
    channel_name,
    adstock_spend,
    saturation_halfpoint_daily as saturation_halfpoint,
    saturation_alpha,
    saturated_spend,
    saturation_efficiency_pct,
    CASE
        WHEN spend_ratio < 0.7 THEN 'Under-invested'
        WHEN spend_ratio <= 1.3 THEN 'Optimal'
        ELSE 'Over-saturated'
    END as saturation_status
FROM with_metrics
ORDER BY metric_date, channel_name
SQL

# Model 8: int_mmm__incremental_revenue
echo "Creating int_mmm__incremental_revenue..."
cat > models/intermediate/mmm/int_mmm__incremental_revenue.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='intermediate'
    )
}}

WITH channel_coefficients AS (
    SELECT 'Email' as channel_name, 4.5 as coefficient
    UNION ALL
    SELECT 'Paid Search' as channel_name, 3.8 as coefficient
    UNION ALL
    SELECT 'Social Media' as channel_name, 3.2 as coefficient
    UNION ALL
    SELECT 'Display Ads' as channel_name, 2.8 as coefficient
    UNION ALL
    SELECT 'TV/Video' as channel_name, 2.5 as coefficient
),

saturation_with_coef AS (
    SELECT
        s.metric_date,
        s.channel_id,
        s.channel_name,
        s.adstock_spend,
        s.saturated_spend,
        cc.coefficient as channel_coefficient,
        a.raw_spend
    FROM {{ ref('int_mmm__saturation_curves') }} s
    JOIN channel_coefficients cc ON s.channel_name = cc.channel_name
    JOIN {{ ref('int_mmm__adstock_transformed') }} a
        ON s.metric_date = a.metric_date AND s.channel_name = a.channel_name
),

revenue_calc AS (
    SELECT
        metric_date,
        channel_id,
        channel_name,
        raw_spend,
        saturated_spend,
        channel_coefficient,
        saturated_spend * channel_coefficient as incremental_revenue,
        CASE
            WHEN raw_spend > 0 THEN (saturated_spend * channel_coefficient) / raw_spend
            ELSE 0
        END as raw_roas,
        CASE
            WHEN saturated_spend > 0 THEN (saturated_spend * channel_coefficient) / saturated_spend
            ELSE 0
        END as effective_roas
    FROM saturation_with_coef
)

SELECT
    metric_date,
    channel_id,
    channel_name,
    saturated_spend,
    channel_coefficient,
    incremental_revenue,
    raw_roas,
    effective_roas
FROM revenue_calc
ORDER BY metric_date, channel_name
SQL

# Model 9: int_mmm__daily_decomposition
echo "Creating int_mmm__daily_decomposition..."
cat > models/intermediate/mmm/int_mmm__daily_decomposition.sql <<'SQL'
{{
    config(
        materialized='view',
        schema='intermediate'
    )
}}

WITH actual_sales AS (
    SELECT
        metric_date,
        SUM(total_revenue) AS actual_sales
    FROM {{ ref('stg_mmm__daily_sales') }}
    GROUP BY metric_date
),

baseline AS (
    SELECT
        metric_date,
        baseline_revenue AS baseline_sales
    FROM {{ ref('int_mmm__baseline_sales') }}
),

incremental_by_channel AS (
    SELECT
        metric_date,
        channel_id,
        channel_name,
        SUM(incremental_revenue) AS channel_incremental_raw
    FROM {{ ref('int_mmm__incremental_revenue') }}
    GROUP BY metric_date, channel_id, channel_name
),

daily_totals AS (
    SELECT
        i.metric_date,
        SUM(i.channel_incremental_raw) AS total_incremental_raw
    FROM incremental_by_channel i
    GROUP BY i.metric_date
),

date_bounds AS (
    SELECT
        GREATEST(MIN(a.metric_date), MIN(b.metric_date)) AS min_date,
        LEAST(MAX(a.metric_date), MAX(b.metric_date)) AS max_date
    FROM actual_sales a
    CROSS JOIN baseline b
),

targets AS (
    SELECT
        a.metric_date,
        a.actual_sales,
        b.baseline_sales,
        GREATEST(a.actual_sales - b.baseline_sales, 0) AS target_incremental,
        d.total_incremental_raw,
        CASE
            WHEN d.total_incremental_raw > 0 THEN (GREATEST(a.actual_sales - b.baseline_sales, 0) / d.total_incremental_raw)
            ELSE 0
        END AS scale_factor
    FROM actual_sales a
    LEFT JOIN baseline b ON a.metric_date = b.metric_date
    LEFT JOIN daily_totals d ON a.metric_date = d.metric_date
    CROSS JOIN date_bounds r
    WHERE a.metric_date BETWEEN r.min_date AND r.max_date
),

scaled AS (
    SELECT
        i.metric_date,
        i.channel_id,
        i.channel_name,
        i.channel_incremental_raw * t.scale_factor AS channel_incremental
    FROM incremental_by_channel i
    JOIN targets t ON i.metric_date = t.metric_date
),

pivoted AS (
    SELECT
        metric_date,
        MAX(CASE WHEN channel_name = 'Email' THEN channel_incremental ELSE 0 END) AS email_incremental,
        MAX(CASE WHEN channel_name = 'Paid Search' THEN channel_incremental ELSE 0 END) AS paid_search_incremental,
        MAX(CASE WHEN channel_name = 'Social Media' THEN channel_incremental ELSE 0 END) AS social_incremental,
        MAX(CASE WHEN channel_name = 'Display Ads' THEN channel_incremental ELSE 0 END) AS display_incremental,
        MAX(CASE WHEN channel_name = 'TV/Video' THEN channel_incremental ELSE 0 END) AS tv_incremental
    FROM scaled
    GROUP BY metric_date
)

SELECT
    t.metric_date,
    t.actual_sales,
    COALESCE(t.baseline_sales, 0) AS baseline_sales,
    COALESCE(p.email_incremental, 0) AS email_incremental,
    COALESCE(p.paid_search_incremental, 0) AS paid_search_incremental,
    COALESCE(p.social_incremental, 0) AS social_incremental,
    COALESCE(p.display_incremental, 0) AS display_incremental,
    COALESCE(p.tv_incremental, 0) AS tv_incremental,
    COALESCE(p.email_incremental, 0) + COALESCE(p.paid_search_incremental, 0) +
    COALESCE(p.social_incremental, 0) + COALESCE(p.display_incremental, 0) +
    COALESCE(p.tv_incremental, 0) AS total_incremental,
    COALESCE(t.baseline_sales, 0) +
    COALESCE(p.email_incremental, 0) + COALESCE(p.paid_search_incremental, 0) +
    COALESCE(p.social_incremental, 0) + COALESCE(p.display_incremental, 0) +
    COALESCE(p.tv_incremental, 0) AS model_predicted_sales,
    t.actual_sales - (
        COALESCE(t.baseline_sales, 0) +
        COALESCE(p.email_incremental, 0) + COALESCE(p.paid_search_incremental, 0) +
        COALESCE(p.social_incremental, 0) + COALESCE(p.display_incremental, 0) +
        COALESCE(p.tv_incremental, 0)
    ) AS residual,
    CASE WHEN t.actual_sales > 0
         THEN (t.actual_sales - (
             COALESCE(t.baseline_sales, 0) +
             COALESCE(p.email_incremental, 0) + COALESCE(p.paid_search_incremental, 0) +
             COALESCE(p.social_incremental, 0) + COALESCE(p.display_incremental, 0) +
             COALESCE(p.tv_incremental, 0)
         )) / t.actual_sales * 100
         ELSE 0
    END AS residual_pct
FROM targets t
LEFT JOIN pivoted p ON t.metric_date = p.metric_date
SQL

echo ""
echo "MARTS LAYER (6 models)"
echo "-------------------------------------"

# Model 10: fct_mmm_performance
echo "Creating fct_mmm_performance..."
cat > models/marts/mmm/fct_mmm_performance.sql <<'SQL'
{{
    config(
        materialized='table',
        schema='marts'
    )
}}

WITH daily_performance AS (
    SELECT
        i.metric_date,
        i.channel_name,
        a.raw_spend,
        a.adstock_spend,
        s.saturated_spend,
        i.incremental_revenue,
        i.raw_roas,
        i.effective_roas,
        s.saturation_efficiency_pct
    FROM {{ ref('int_mmm__incremental_revenue') }} i
    JOIN {{ ref('int_mmm__adstock_transformed') }} a
        ON i.metric_date = a.metric_date AND i.channel_name = a.channel_name
    JOIN {{ ref('int_mmm__saturation_curves') }} s
        ON i.metric_date = s.metric_date AND i.channel_name = s.channel_name
),

total_sales AS (
    SELECT
        metric_date,
        actual_sales
    FROM {{ ref('int_mmm__daily_decomposition') }}
),

with_contribution AS (
    SELECT
        p.metric_date,
        ROW_NUMBER() OVER (ORDER BY p.channel_name) as channel_id,
        p.channel_name,
        p.raw_spend,
        p.adstock_spend,
        p.saturated_spend,
        p.incremental_revenue,
        p.raw_roas,
        p.effective_roas,
        p.saturation_efficiency_pct,
        CASE
            WHEN ts.actual_sales > 0 THEN 100.0 * p.incremental_revenue / ts.actual_sales
            ELSE 0
        END as contribution_to_total_sales_pct
    FROM daily_performance p
    LEFT JOIN total_sales ts ON p.metric_date = ts.metric_date
)

SELECT
    metric_date,
    channel_id,
    channel_name,
    raw_spend,
    adstock_spend,
    saturated_spend,
    incremental_revenue,
    raw_roas,
    effective_roas,
    saturation_efficiency_pct,
    contribution_to_total_sales_pct
FROM with_contribution
ORDER BY metric_date, channel_name
SQL

# Model 11: rpt_mmm_channel_effectiveness
echo "Creating rpt_mmm_channel_effectiveness..."
cat > models/marts/mmm/rpt_mmm_channel_effectiveness.sql <<'SQL'
{{
    config(
        materialized='table',
        schema='marts'
    )
}}

WITH channel_aggregates AS (
    SELECT
        channel_name,
        SUM(raw_spend) as total_raw_spend,
        SUM(incremental_revenue) as total_incremental_revenue,
        AVG(saturation_efficiency_pct) as avg_saturation_efficiency_pct,
        AVG(raw_spend) as avg_daily_spend
    FROM {{ ref('fct_mmm_performance') }}
    GROUP BY channel_name
),

channel_params AS (
    SELECT
        channel_name,
        channel_type,
        saturation_halfpoint_daily,
        saturation_alpha
    FROM {{ ref('stg_mmm__channel_mapping') }}
),

channel_coefficients AS (
    SELECT 'Email' as channel_name, 4.5 as coefficient
    UNION ALL
    SELECT 'Paid Search' as channel_name, 3.8 as coefficient
    UNION ALL
    SELECT 'Social Media' as channel_name, 3.2 as coefficient
    UNION ALL
    SELECT 'Display Ads' as channel_name, 2.8 as coefficient
    UNION ALL
    SELECT 'TV/Video' as channel_name, 2.5 as coefficient
),

with_metrics AS (
    SELECT
        ca.channel_name,
        cp.channel_type,
        ca.total_raw_spend,
        ca.total_incremental_revenue,
        ca.avg_saturation_efficiency_pct,
        CASE
            WHEN ca.total_raw_spend > 0 THEN ca.total_incremental_revenue / ca.total_raw_spend
            ELSE 0
        END as raw_roas,
        ca.avg_daily_spend / cp.saturation_halfpoint_daily as avg_spend_ratio,
        CASE
            WHEN ca.avg_daily_spend > 0 THEN
                cc.coefficient * cp.saturation_alpha * POWER(cp.saturation_halfpoint_daily, cp.saturation_alpha) *
                POWER(ca.avg_daily_spend, cp.saturation_alpha - 1) /
                POWER(POWER(ca.avg_daily_spend, cp.saturation_alpha) + POWER(cp.saturation_halfpoint_daily, cp.saturation_alpha), 2)
            ELSE cc.coefficient
        END as marginal_roas
    FROM channel_aggregates ca
    JOIN channel_params cp ON ca.channel_name = cp.channel_name
    JOIN channel_coefficients cc ON ca.channel_name = cc.channel_name
),

with_status AS (
    SELECT
        channel_name,
        channel_type,
        total_raw_spend,
        total_incremental_revenue,
        avg_saturation_efficiency_pct,
        raw_roas,
        marginal_roas,
        CASE
            WHEN avg_spend_ratio < 0.7 THEN 'Under-invested'
            WHEN avg_spend_ratio <= 1.3 THEN 'Optimal'
            ELSE 'Over-saturated'
        END as saturation_status,
        CASE
            WHEN avg_spend_ratio < 0.7 THEN 'Increase'
            WHEN avg_spend_ratio <= 1.3 THEN 'Maintain'
            ELSE 'Decrease'
        END as recommended_action
    FROM with_metrics
)

SELECT
    ROW_NUMBER() OVER (ORDER BY channel_name) as channel_id,
    channel_name,
    channel_type,
    total_raw_spend,
    total_incremental_revenue,
    avg_saturation_efficiency_pct,
    raw_roas,
    marginal_roas,
    saturation_status,
    ROW_NUMBER() OVER (ORDER BY marginal_roas DESC) as rank_by_effectiveness,
    recommended_action
FROM with_status
ORDER BY marginal_roas DESC
SQL

# Model 12: rpt_mmm_budget_optimization
echo "Creating rpt_mmm_budget_optimization..."
cat > models/marts/mmm/rpt_mmm_budget_optimization.sql <<'SQL'
{{
    config(
        materialized='table',
        schema='marts'
    )
}}

WITH daily_spend AS (
    SELECT
        channel_id,
        channel_name,
        AVG(raw_spend) AS avg_daily_spend
    FROM {{ ref('fct_mmm_performance') }}
    GROUP BY channel_id, channel_name
),

current_budget AS (
    SELECT
        channel_id,
        channel_name,
        avg_daily_spend * 30 AS current_budget
    FROM daily_spend
),

effectiveness AS (
    SELECT
        channel_id,
        channel_name,
        marginal_roas AS current_marginal_roas
    FROM {{ ref('rpt_mmm_channel_effectiveness') }}
),

total_budget_calc AS (
    SELECT SUM(current_budget) AS total_budget
    FROM current_budget
),

optimization AS (
    SELECT
        c.channel_id,
        c.channel_name,
        c.current_budget,
        e.current_marginal_roas,
        t.total_budget,
        (e.current_marginal_roas / SUM(e.current_marginal_roas) OVER ()) * t.total_budget AS recommended_raw
    FROM current_budget c
    LEFT JOIN effectiveness e ON c.channel_name = e.channel_name
    CROSS JOIN total_budget_calc t
),

clamped AS (
    SELECT
        channel_id,
        channel_name,
        current_budget,
        current_marginal_roas,
        total_budget,
        GREATEST(20000, LEAST(200000, recommended_raw)) AS recommended_clamped
    FROM optimization
),

alloc AS (
    SELECT
        channel_id,
        channel_name,
        current_budget,
        current_marginal_roas,
        total_budget,
        recommended_clamped,
        SUM(recommended_clamped) OVER () AS total_clamped,
        SUM(CASE WHEN recommended_clamped BETWEEN 20000 AND 200000 THEN current_marginal_roas ELSE 0 END)
            OVER () AS sum_marginal_roas
    FROM clamped
),

final AS (
    SELECT
        channel_id,
        channel_name,
        current_budget,
        current_marginal_roas,
        total_budget,
        GREATEST(20000, LEAST(200000,
            CASE
                WHEN sum_marginal_roas > 0 THEN
                    recommended_clamped + (total_budget - total_clamped) * (current_marginal_roas / sum_marginal_roas)
                ELSE recommended_clamped
            END
        )) AS recommended_budget
    FROM alloc
)

SELECT
    channel_id,
    channel_name,
    current_budget,
    (current_budget / total_budget) * 100 AS current_budget_pct,
    current_marginal_roas,
    recommended_budget,
    (recommended_budget / total_budget) * 100 AS recommended_budget_pct,
    recommended_budget - current_budget AS budget_change,
    CASE WHEN current_budget > 0
         THEN ((recommended_budget - current_budget) / current_budget) * 100
         ELSE 0
    END AS budget_change_pct,
    (recommended_budget - current_budget) * current_marginal_roas AS expected_revenue_change
FROM final
SQL

# Model 13: rpt_mmm_decomposition
echo "Creating rpt_mmm_decomposition..."
cat > models/marts/mmm/rpt_mmm_decomposition.sql <<'SQL'
{{
    config(
        materialized='table',
        schema='marts'
    )
}}

SELECT
    metric_date,
    actual_sales,
    baseline_sales,
    CASE WHEN actual_sales > 0 THEN (baseline_sales / actual_sales) * 100 ELSE 0 END AS baseline_pct,
    email_incremental,
    CASE WHEN actual_sales > 0 THEN (email_incremental / actual_sales) * 100 ELSE 0 END AS email_pct,
    paid_search_incremental,
    CASE WHEN actual_sales > 0 THEN (paid_search_incremental / actual_sales) * 100 ELSE 0 END AS paid_search_pct,
    social_incremental,
    CASE WHEN actual_sales > 0 THEN (social_incremental / actual_sales) * 100 ELSE 0 END AS social_pct,
    display_incremental,
    CASE WHEN actual_sales > 0 THEN (display_incremental / actual_sales) * 100 ELSE 0 END AS display_pct,
    tv_incremental,
    CASE WHEN actual_sales > 0 THEN (tv_incremental / actual_sales) * 100 ELSE 0 END AS tv_pct,
    total_incremental AS total_marketing_incremental,
    CASE WHEN actual_sales > 0 THEN (total_incremental / actual_sales) * 100 ELSE 0 END AS marketing_pct,
    residual,
    residual_pct
FROM {{ ref('int_mmm__daily_decomposition') }}
SQL

# Model 14: rpt_mmm_saturation_analysis
echo "Creating rpt_mmm_saturation_analysis..."
cat > models/marts/mmm/rpt_mmm_saturation_analysis.sql <<'SQL'
{{
    config(
        materialized='table',
        schema='marts'
    )
}}

WITH monthly_spend AS (
    SELECT
        channel_id,
        channel_name,
        AVG(raw_spend) * 30 AS current_spend_level
    FROM {{ ref('fct_mmm_performance') }}
    GROUP BY channel_id, channel_name
),

channel_params AS (
    SELECT
        channel_id,
        channel_name,
        saturation_halfpoint / 30.0 AS saturation_halfpoint
    FROM {{ ref('stg_mmm__channel_mapping') }}
),

effectiveness AS (
    SELECT
        channel_id,
        channel_name,
        avg_saturation_efficiency_pct AS current_efficiency_pct
    FROM {{ ref('rpt_mmm_channel_effectiveness') }}
)

SELECT
    s.channel_id,
    s.channel_name,
    s.current_spend_level,
    p.saturation_halfpoint,
    s.current_spend_level / NULLIF(p.saturation_halfpoint, 0) AS spend_vs_halfpoint_ratio,
    100.0 / (1 + (s.current_spend_level / NULLIF(p.saturation_halfpoint, 1))) AS current_efficiency_pct,
    p.saturation_halfpoint AS optimal_spend_level,
    s.current_spend_level - p.saturation_halfpoint AS spend_gap,
    CASE WHEN s.current_spend_level > p.saturation_halfpoint * 1.3 THEN 1 ELSE 0 END AS is_oversaturated
FROM monthly_spend s
LEFT JOIN channel_params p ON s.channel_name = p.channel_name
LEFT JOIN effectiveness e ON s.channel_name = e.channel_name
SQL

# Model 15: rpt_mmm_summary
echo "Creating rpt_mmm_summary..."
cat > models/marts/mmm/rpt_mmm_summary.sql <<'SQL'
{{
    config(
        materialized='table',
        schema='marts'
    )
}}

WITH weekly_summary AS (
    SELECT
        DATE_TRUNC('week', d.metric_date) AS time_period,
        SUM(d.actual_sales) AS total_sales,
        SUM(d.baseline_sales) AS baseline_sales,
        SUM(d.total_incremental) AS total_marketing_incremental,
        SUM(f.raw_spend) AS total_marketing_spend
    FROM {{ ref('int_mmm__daily_decomposition') }} d
    LEFT JOIN (
        SELECT metric_date, SUM(raw_spend) AS raw_spend
        FROM {{ ref('fct_mmm_performance') }}
        GROUP BY metric_date
    ) f ON d.metric_date = f.metric_date
    GROUP BY DATE_TRUNC('week', d.metric_date)
),

with_metrics AS (
    SELECT
        time_period,
        total_sales,
        baseline_sales,
        CASE WHEN total_sales > 0 THEN (baseline_sales / total_sales) * 100 ELSE 0 END AS baseline_pct,
        total_marketing_incremental,
        CASE WHEN total_sales > 0 THEN (total_marketing_incremental / total_sales) * 100 ELSE 0 END AS marketing_pct,
        total_marketing_spend,
        CASE WHEN total_marketing_spend > 0
             THEN total_marketing_incremental / total_marketing_spend
             ELSE 0
        END AS overall_marketing_roas
    FROM weekly_summary
),

avg_efficiency AS (
    SELECT
        AVG(avg_saturation_efficiency_pct) AS avg_saturation_efficiency_pct
    FROM {{ ref('rpt_mmm_channel_effectiveness') }}
),

top_channel AS (
    SELECT channel_name
    FROM {{ ref('rpt_mmm_channel_effectiveness') }}
    ORDER BY marginal_roas DESC
    LIMIT 1
),

most_saturated AS (
    SELECT channel_name
    FROM {{ ref('rpt_mmm_channel_effectiveness') }}
    ORDER BY avg_saturation_efficiency_pct ASC
    LIMIT 1
)

SELECT
    m.time_period,
    m.total_sales,
    m.baseline_sales,
    m.baseline_pct,
    m.total_marketing_incremental,
    m.marketing_pct,
    m.total_marketing_spend,
    m.overall_marketing_roas,
    e.avg_saturation_efficiency_pct,
    t.channel_name AS top_performing_channel,
    s.channel_name AS most_saturated_channel
FROM with_metrics m
CROSS JOIN avg_efficiency e
CROSS JOIN top_channel t
CROSS JOIN most_saturated s
SQL

echo ""
echo "Step 3: Installing dbt dependencies..."
echo "-------------------------------------"
dbt deps --profiles-dir .

echo ""
echo "Step 4: Running dbt models..."
echo "-------------------------------------"
dbt run --profiles-dir . --select stg_mmm__daily_sales stg_mmm__marketing_spend stg_mmm__calendar stg_mmm__channel_mapping
dbt run --profiles-dir . --select int_mmm__baseline_sales int_mmm__adstock_transformed int_mmm__saturation_curves int_mmm__incremental_revenue int_mmm__daily_decomposition
dbt run --profiles-dir . --select fct_mmm_performance rpt_mmm_channel_effectiveness rpt_mmm_budget_optimization rpt_mmm_decomposition rpt_mmm_saturation_analysis rpt_mmm_summary

echo ""
echo "========================================="
echo "Solution complete!"
echo "========================================="
