{{
    config(
        materialized='table',
        tags=['dimension', 'entries', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_time_entries') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['entry_id']) }} AS entries_key,
        entry_id AS entries_id,
        
        -- Attributes
        employee_id,
        entry_date,
        clock_in,
        clock_out,
        break_minutes,
        hours_worked,
        entry_type,
        status,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE entry_id IS NOT NULL
)

SELECT * FROM final
