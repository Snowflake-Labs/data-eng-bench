{{
    config(
        materialized='table',
        tags=['dimension', 'departments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_employee_departments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['assignment_id']) }} AS departments_key,
        assignment_id AS departments_id,
        
        -- Attributes
        employee_id,
        department_id,
        start_date,
        end_date,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE assignment_id IS NOT NULL
)

SELECT * FROM final
