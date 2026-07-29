{{
    config(
        materialized='table',
        tags=['dimension', 'tiers', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_account_tiers') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['tier_id']) }} AS tiers_key,
        tier_id AS tiers_id,

        -- Attributes
        tier_code,
        tier_name,
        tier_level,
        min_points_required,
        min_spend_required,
        points_multiplier,
        discount_percentage,
        free_shipping,
        benefits_description,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE tier_id IS NOT NULL
)

SELECT * FROM final
