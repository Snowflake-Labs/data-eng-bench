{{
    config(
        materialized='table',
        tags=['dimension', 'employee', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_dim_employee') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['employee_id']) }} AS employee_key,
        employee_id,

        -- Attributes
        employee_number,
        employee_name,
        department_name,
        position_title,
        manager_name,
        hire_date,
        is_active,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE employee_id IS NOT NULL
)

SELECT * FROM final
