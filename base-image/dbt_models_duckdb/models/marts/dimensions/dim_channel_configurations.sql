{{
    config(
        materialized='table',
        tags=['dimension', 'configurations', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_channel_configurations') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['config_id']) }} AS configurations_key,
        config_id AS configurations_id,
        
        -- Attributes
        channel_id,
        config_key,
        config_value,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE config_id IS NOT NULL
)

SELECT * FROM final
