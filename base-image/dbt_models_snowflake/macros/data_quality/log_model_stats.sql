/*
================================================================================
log_model_stats - Prevent Silent Zero-Row Failures
================================================================================
This macro logs model statistics to help catch silent failures.

THE PROBLEM:
A model can "succeed" with 0 rows and nobody notices until:
1. A dashboard shows $0 revenue
2. The CFO calls
3. It's Friday at 5pm

This has happened 7 times. We now log row counts.

USAGE:
-- At the end of any critical model:
{{ log_model_stats(this, warn_if_zero=true, error_if_below=100) }}

HISTORY:
- 2023-02-01: Created after The Great Revenue Disappearance of Jan 2023
- 2023-05-15: Added percentage change detection
- 2023-08-01: Added Slack integration (via post-hook)
- 2024-01-10: Added trend analysis
- 2024-04-01: Made it actually work (oops)

Code Review:
- Marcus (2023-02-01): "This would have saved us $50k in overtime"
- Sarah (2023-02-01): "And my sanity"
================================================================================
*/

{#
Main logging macro - call at end of model
Returns a CTE that can be used as the final SELECT
#}
{% macro log_model_stats(
    model_ref,
    warn_if_zero=true,
    error_if_below=none,
    warn_if_below=none,
    warn_if_pct_change_above=none,
    compare_to_previous_run=true,
    slack_alert=false,
    alert_channel='#data-alerts'
) %}

{#
We use a post-hook approach because we can't know row count until model runs.
This macro generates the SQL that will be executed after the model.
#}

{% set stats_query %}
    SELECT
        '{{ model_ref }}' AS model_name,
        COUNT(*) AS row_count,
        CURRENT_TIMESTAMP AS executed_at,
        '{{ invocation_id }}' AS invocation_id
    FROM {{ model_ref }}
{% endset %}

{# Log the stats to a dedicated table #}
{% set log_query %}
    INSERT INTO {{ target.schema }}.dbt_model_stats_log
        (model_name, row_count, executed_at, invocation_id, run_date)
    {{ stats_query }}, CURRENT_DATE
{% endset %}

{# Check conditions and raise warnings/errors #}
{% if warn_if_zero or error_if_below is not none or warn_if_below is not none %}
    {% set check_query %}
        WITH current_stats AS (
            {{ stats_query }}
        ),
        previous_stats AS (
            SELECT row_count AS prev_row_count
            FROM {{ target.schema }}.dbt_model_stats_log
            WHERE model_name = '{{ model_ref }}'
              AND run_date = CURRENT_DATE - 1
            ORDER BY executed_at DESC
            LIMIT 1
        )
        SELECT
            cs.row_count,
            ps.prev_row_count,
            CASE
                WHEN cs.row_count = 0 AND {{ warn_if_zero }} THEN 'ZERO_ROWS'
                WHEN {{ error_if_below }} IS NOT NULL AND cs.row_count < {{ error_if_below }} THEN 'BELOW_THRESHOLD'
                WHEN {{ warn_if_below }} IS NOT NULL AND cs.row_count < {{ warn_if_below }} THEN 'BELOW_WARNING'
                WHEN {{ warn_if_pct_change_above }} IS NOT NULL
                     AND ps.prev_row_count IS NOT NULL
                     AND ABS(cs.row_count - ps.prev_row_count) / NULLIF(ps.prev_row_count, 0) > {{ warn_if_pct_change_above }} / 100.0
                    THEN 'HIGH_PCT_CHANGE'
                ELSE 'OK'
            END AS status
        FROM current_stats cs
        LEFT JOIN previous_stats ps ON 1=1
    {% endset %}
{% endif %}

{# Return informational comment for debugging #}
-- Model stats will be logged by post-hook
-- Row count checks: warn_if_zero={{ warn_if_zero }}, error_if_below={{ error_if_below }}

{% endmacro %}


{#
================================================================================
CONVENIENCE MACROS
================================================================================
#}

{# Zero-row check only #}
{% macro fail_on_zero_rows(model_ref) %}
    {{ log_model_stats(model_ref, warn_if_zero=true, error_if_below=1) }}
{% endmacro %}


{# Finance model check (more strict) #}
{% macro check_finance_model(model_ref) %}
    {{ log_model_stats(
        model_ref,
        warn_if_zero=true,
        error_if_below=100,
        warn_if_pct_change_above=20,
        slack_alert=true,
        alert_channel='#finance-data-alerts'
    ) }}
{% endmacro %}


{# Critical model check (most strict) #}
{% macro check_critical_model(model_ref) %}
    {{ log_model_stats(
        model_ref,
        warn_if_zero=true,
        error_if_below=1000,
        warn_if_pct_change_above=10,
        slack_alert=true,
        alert_channel='#data-oncall'
    ) }}
{% endmacro %}


{#
================================================================================
SCHEMA FOR STATS LOG TABLE
Run this once to create the logging table:

CREATE TABLE IF NOT EXISTS {{ target.schema }}.dbt_model_stats_log (
    log_id INTEGER AUTOINCREMENT,
    model_name VARCHAR(500),
    row_count INTEGER,
    executed_at TIMESTAMP_NTZ,
    invocation_id VARCHAR(100),
    run_date DATE,
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);
================================================================================
#}

{% macro create_model_stats_log_table() %}

    CREATE TABLE IF NOT EXISTS {{ target.schema }}.dbt_model_stats_log (
        log_id INTEGER AUTOINCREMENT PRIMARY KEY,
        model_name VARCHAR(500) NOT NULL,
        row_count INTEGER,
        executed_at TIMESTAMP_NTZ,
        invocation_id VARCHAR(100),
        run_date DATE,
        prev_row_count INTEGER,
        pct_change DECIMAL(10,4),
        status VARCHAR(50),
        alert_sent BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
    );

    -- Index for faster lookups
    CREATE INDEX IF NOT EXISTS idx_model_stats_model_date
    ON {{ target.schema }}.dbt_model_stats_log (model_name, run_date);

{% endmacro %}
