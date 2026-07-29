{{
    config(
        materialized='table',
        tags=['dimension', 'notes', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg__lookup_analyst_notes') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['id']) }} AS notes_key,
        id AS notes_id,
        
        -- Attributes
        text_value,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE id IS NOT NULL
)

SELECT * FROM final
