{{
    config(
        materialized='table',
        tags=['dimension', 'runs', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_payroll_runs') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['payroll_run_id']) }} AS runs_key,
        payroll_run_id AS runs_id,

        -- Attributes
        payroll_period,
        period_start,
        period_end,
        pay_date,
        status,
        total_gross,
        total_net,
        employee_count,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE payroll_run_id IS NOT NULL
)

SELECT * FROM final
