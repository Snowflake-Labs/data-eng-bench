{{
    config(
        materialized='table',
        tags=['dimension', 'schedules', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_employee_schedules') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['schedule_id']) }} AS schedules_key,
        schedule_id AS schedules_id,
        
        -- Attributes
        employee_id,
        schedule_date,
        shift_type,
        start_time,
        end_time,
        location_id,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE schedule_id IS NOT NULL
)

SELECT * FROM final
