{{
    config(
        materialized='table',
        tags=['dimension', 'channels', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_campaign_channels') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['channel_mapping_id']) }} AS channels_key,
        channel_mapping_id AS channels_id,
        
        -- Attributes
        campaign_id,
        channel_type,
        allocated_budget,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE channel_mapping_id IS NOT NULL
)

SELECT * FROM final
