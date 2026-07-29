/*
================================================================================
dq_checks - Data Quality Check Macros
================================================================================
Collection of DQ check macros used across models.

These evolved from "we should add some checks" to "these saved us from
several P1 incidents" over the course of 2 years.

The naming convention is intentional:
- dq_check_* : Returns boolean (pass/fail)
- dq_flag_* : Returns string flag for categorization
- dq_alert_* : Triggers alerting if condition met

USAGE:
WITH source AS (...),
validated AS (
    SELECT
        *,
        {{ dq_flag_revenue_anomaly('line_total', 'order_date') }} AS dq_revenue_flag,
        {{ dq_check_required_field('customer_id') }} AS dq_customer_valid
    FROM source
)
SELECT * FROM validated WHERE dq_customer_valid = TRUE

HISTORY:
- 2023-01-01: Basic null/range checks
- 2023-04-15: Added anomaly detection after Black Friday incident
- 2023-08-01: Added PII detection
- 2024-01-10: Added cross-field validation
- 2024-06-01: Added statistical checks (z-score, IQR)
================================================================================
*/

{#
================================================================================
BASIC VALIDATION CHECKS
================================================================================
#}

{# Check if field is not null and not empty string #}
{% macro dq_check_required_field(column) %}
    CASE
        WHEN {{ column }} IS NULL THEN FALSE
        WHEN TRIM({{ column }}::VARCHAR) = '' THEN FALSE
        ELSE TRUE
    END
{% endmacro %}


{# Check if value is within expected range #}
{% macro dq_check_range(column, min_val=none, max_val=none, allow_null=true) %}
    CASE
        WHEN {{ column }} IS NULL THEN {{ allow_null }}
        {% if min_val is not none %}
        WHEN {{ column }} < {{ min_val }} THEN FALSE
        {% endif %}
        {% if max_val is not none %}
        WHEN {{ column }} > {{ max_val }} THEN FALSE
        {% endif %}
        ELSE TRUE
    END
{% endmacro %}


{# Check if value is in allowed list #}
{% macro dq_check_allowed_values(column, allowed_values, allow_null=true) %}
    CASE
        WHEN {{ column }} IS NULL THEN {{ allow_null }}
        WHEN {{ column }} IN ({{ allowed_values | join(', ') }}) THEN TRUE
        ELSE FALSE
    END
{% endmacro %}


{# Check if date is reasonable (not in future, not too far in past) #}
{% macro dq_check_date_reasonable(column, min_date="'2015-01-01'", allow_future_days=1) %}
    CASE
        WHEN {{ column }} IS NULL THEN TRUE  -- NULL dates handled separately
        WHEN {{ column }} < {{ min_date }} THEN FALSE
        WHEN {{ column }} > DATEADD('day', {{ allow_future_days }}, CURRENT_DATE) THEN FALSE
        ELSE TRUE
    END
{% endmacro %}


{#
================================================================================
ANOMALY DETECTION FLAGS
================================================================================
#}

{# Flag revenue anomalies based on historical patterns #}
{% macro dq_flag_revenue_anomaly(amount_col, date_col, threshold_multiplier=3) %}
    CASE
        -- Negative non-return amounts
        WHEN {{ amount_col }} < 0 THEN 'NEGATIVE_AMOUNT'

        -- Zero amounts (suspicious for revenue)
        WHEN {{ amount_col }} = 0 THEN 'ZERO_AMOUNT'

        -- Unusually high amounts (> 3x typical)
        WHEN {{ amount_col }} > 10000 THEN 'HIGH_AMOUNT'

        -- Amounts with suspicious precision (might be test data)
        WHEN {{ amount_col }} = ROUND({{ amount_col }}, 0)
             AND {{ amount_col }} > 100
             AND MOD({{ amount_col }}::INTEGER, 100) = 0 THEN 'ROUND_NUMBER_SUSPECT'

        -- Weekend spikes (might be batch processing error)
        WHEN DAYOFWEEK({{ date_col }}) IN (0, 6)
             AND {{ amount_col }} > 5000 THEN 'WEEKEND_HIGH_AMOUNT'

        ELSE NULL
    END
{% endmacro %}


{# Flag quantity anomalies #}
{% macro dq_flag_quantity_anomaly(quantity_col) %}
    CASE
        WHEN {{ quantity_col }} IS NULL THEN 'NULL_QUANTITY'
        WHEN {{ quantity_col }} < 0 THEN 'NEGATIVE_QUANTITY'
        WHEN {{ quantity_col }} = 0 THEN 'ZERO_QUANTITY'
        WHEN {{ quantity_col }} > 10000 THEN 'BULK_ORDER'
        WHEN {{ quantity_col }} != ROUND({{ quantity_col }}, 0) THEN 'FRACTIONAL_QUANTITY'
        ELSE NULL
    END
{% endmacro %}


{# Flag potential duplicate records #}
{% macro dq_flag_potential_duplicate(partition_cols, order_col) %}
    CASE
        WHEN COUNT(*) OVER (PARTITION BY {{ partition_cols | join(', ') }}) > 1 THEN 'POTENTIAL_DUPLICATE'
        ELSE NULL
    END
{% endmacro %}


{#
================================================================================
CROSS-FIELD VALIDATION
================================================================================
#}

{# Check that shipped quantity doesn't exceed ordered #}
{% macro dq_check_shipped_vs_ordered(shipped_col, ordered_col, tolerance_pct=5) %}
    CASE
        WHEN {{ shipped_col }} IS NULL OR {{ ordered_col }} IS NULL THEN TRUE
        WHEN {{ shipped_col }} > {{ ordered_col }} * (1 + {{ tolerance_pct }}/100.0) THEN FALSE
        ELSE TRUE
    END
{% endmacro %}


{# Check that dates are in logical order #}
{% macro dq_check_date_sequence(dates_in_order) %}
{# dates_in_order should be a list of column names in expected chronological order #}
    CASE
        {% for i in range(dates_in_order | length - 1) %}
        WHEN {{ dates_in_order[i] }} IS NOT NULL
             AND {{ dates_in_order[i+1] }} IS NOT NULL
             AND {{ dates_in_order[i] }} > {{ dates_in_order[i+1] }} THEN FALSE
        {% endfor %}
        ELSE TRUE
    END
{% endmacro %}


{# Check order totals match line items #}
{% macro dq_check_order_total_matches_lines(order_total_col, line_total_col, order_id_col, tolerance=0.01) %}
    CASE
        WHEN ABS(
            {{ order_total_col }} - SUM({{ line_total_col }}) OVER (PARTITION BY {{ order_id_col }})
        ) > {{ tolerance }} THEN FALSE
        ELSE TRUE
    END
{% endmacro %}


{#
================================================================================
PII DETECTION (for compliance)
================================================================================
#}

{# Flag potential PII in text fields #}
{% macro dq_flag_potential_pii(text_col) %}
    CASE
        -- Email pattern
        WHEN REGEXP_LIKE({{ text_col }}, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}') THEN 'CONTAINS_EMAIL'

        -- Phone pattern (US format)
        WHEN REGEXP_LIKE({{ text_col }}, '\\b\\d{3}[-.]?\\d{3}[-.]?\\d{4}\\b') THEN 'CONTAINS_PHONE'

        -- SSN pattern
        WHEN REGEXP_LIKE({{ text_col }}, '\\b\\d{3}-\\d{2}-\\d{4}\\b') THEN 'CONTAINS_SSN'

        -- Credit card pattern (basic)
        WHEN REGEXP_LIKE({{ text_col }}, '\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b') THEN 'CONTAINS_CC'

        ELSE NULL
    END
{% endmacro %}


{#
================================================================================
STATISTICAL CHECKS
================================================================================
#}

{# Z-score outlier detection #}
{% macro dq_check_zscore_outlier(value_col, partition_cols=none, threshold=3) %}
{% set partition_clause = 'PARTITION BY ' ~ partition_cols | join(', ') if partition_cols else '' %}
    CASE
        WHEN ABS(
            ({{ value_col }} - AVG({{ value_col }}) OVER ({{ partition_clause }}))
            / NULLIF(STDDEV({{ value_col }}) OVER ({{ partition_clause }}), 0)
        ) > {{ threshold }} THEN FALSE
        ELSE TRUE
    END
{% endmacro %}


{# IQR outlier detection #}
{% macro dq_flag_iqr_outlier(value_col, partition_cols=none, multiplier=1.5) %}
{% set partition_clause = 'PARTITION BY ' ~ partition_cols | join(', ') if partition_cols else '' %}
    CASE
        WHEN {{ value_col }} < (
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            - {{ multiplier }} * (
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
                - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            )
        ) THEN 'LOW_OUTLIER'
        WHEN {{ value_col }} > (
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            + {{ multiplier }} * (
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
                - PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY {{ value_col }}) OVER ({{ partition_clause }})
            )
        ) THEN 'HIGH_OUTLIER'
        ELSE NULL
    END
{% endmacro %}
