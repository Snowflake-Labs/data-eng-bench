{{
    config(
        materialized='table',
        tags=['dimension', 'channel', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_dim_channel') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['channel_id']) }} AS channel_key,
        channel_id AS channel_id,
        
        -- Attributes
        channel_id,
        channel_code,
        channel_name,
        channel_type,
        is_active,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE channel_id IS NOT NULL
)

SELECT * FROM final
