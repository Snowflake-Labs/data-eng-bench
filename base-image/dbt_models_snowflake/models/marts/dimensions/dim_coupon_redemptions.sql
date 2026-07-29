{{
    config(
        materialized='table',
        tags=['dimension', 'redemptions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_coupon_redemptions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['redemption_id']) }} AS redemptions_key,
        redemption_id AS redemptions_id,

        -- Attributes
        coupon_id,
        order_id,
        customer_id,
        discount_amount,
        redeemed_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE redemption_id IS NOT NULL
)

SELECT * FROM final
