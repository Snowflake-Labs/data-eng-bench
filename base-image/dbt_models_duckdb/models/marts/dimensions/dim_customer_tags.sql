{{
    config(
        materialized='table',
        tags=['dimension', 'tags', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_tags') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['tag_id']) }} AS tags_key,
        tag_id AS tags_id,
        
        -- Attributes
        customer_id,
        tag_name,
        tag_category,
        tag_source,
        applied_at,
        applied_by,
        expires_at,
        is_active,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE tag_id IS NOT NULL
)

SELECT * FROM final
