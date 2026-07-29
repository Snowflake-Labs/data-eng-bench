{{
    config(
        materialized='table',
        tags=['dimension', 'performance', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_campaign_performance') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['performance_id']) }} AS performance_key,
        performance_id AS performance_id,

        -- Attributes
        campaign_id,
        metric_date,
        impressions,
        clicks,
        conversions,
        spend,
        revenue,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE performance_id IS NOT NULL
)

SELECT * FROM final
