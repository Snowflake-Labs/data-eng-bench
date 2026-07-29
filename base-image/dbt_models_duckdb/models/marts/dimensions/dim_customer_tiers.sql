{{
    config(
        materialized='table',
        tags=['dimension', 'tiers', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_tiers') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['tier_code']) }} AS tiers_key,
        tier_code AS tiers_id,

        -- Attributes
        tier_code,
        tier_name,
        min_spend_required,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE tier_code IS NOT NULL
)

SELECT * FROM final
