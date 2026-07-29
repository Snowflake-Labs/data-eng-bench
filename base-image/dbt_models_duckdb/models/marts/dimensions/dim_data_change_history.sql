{{
    config(
        materialized='table',
        tags=['dimension', 'history', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_data_change_history') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['change_id']) }} AS history_key,
        change_id AS history_id,
        
        -- Attributes
        table_name,
        record_id,
        column_name,
        old_value,
        new_value,
        change_type,
        changed_by,
        changed_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE change_id IS NOT NULL
)

SELECT * FROM final
