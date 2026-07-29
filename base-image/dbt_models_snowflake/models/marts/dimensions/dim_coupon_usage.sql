{{
    config(
        materialized='table',
        tags=['dimension', 'usage', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_coupon_usage') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['redemption_id']) }} AS usage_key,
        redemption_id AS usage_id,

        -- Attributes
        coupon_id,
        order_id,
        customer_id,
        discount_amount,
        redeemed_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE redemption_id IS NOT NULL
)

SELECT * FROM final
