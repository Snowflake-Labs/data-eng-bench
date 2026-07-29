{{
    config(
        materialized='table',
        tags=['dimension', 'details', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_payroll_details') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['detail_id']) }} AS details_key,
        detail_id AS details_id,
        
        -- Attributes
        payroll_run_id,
        employee_id,
        gross_pay,
        tax_deductions,
        other_deductions,
        net_pay,
        hours_worked,
        overtime_hours,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE detail_id IS NOT NULL
)

SELECT * FROM final
