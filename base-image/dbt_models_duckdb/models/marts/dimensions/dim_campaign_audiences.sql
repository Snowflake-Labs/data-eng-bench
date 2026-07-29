{{
    config(
        materialized='table',
        tags=['dimension', 'audiences', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_campaign_audiences') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['audience_id']) }} AS audiences_key,
        audience_id AS audiences_id,
        
        -- Attributes
        campaign_id,
        segment_id,
        audience_name,
        audience_size,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE audience_id IS NOT NULL
)

SELECT * FROM final
