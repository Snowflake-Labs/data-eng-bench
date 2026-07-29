{{
    config(
        materialized='table',
        tags=['dimension', 'channels', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_sales_channels') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['channel_id']) }} AS channels_key,
        channel_id AS channels_id,
        
        -- Attributes
        channel_code,
        channel_name,
        channel_type,
        is_active,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE channel_id IS NOT NULL
)

SELECT * FROM final
