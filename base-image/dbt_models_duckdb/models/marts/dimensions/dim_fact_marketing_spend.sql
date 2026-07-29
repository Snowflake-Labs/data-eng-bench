{{
    config(
        materialized='table',
        tags=['dimension', 'spend', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_fact_marketing_spend') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['campaign_id']) }} AS spend_key,
        campaign_id AS spend_id,
        
        -- Attributes
        date_key,
        campaign_id,
        channel_key,
        impressions,
        clicks,
        conversions,
        spend_amount,
        revenue_attributed,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE campaign_id IS NOT NULL
)

SELECT * FROM final
