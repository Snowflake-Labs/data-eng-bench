{{
    config(
        materialized='table',
        tags=['dimension', 'coupons', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_coupons') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['coupon_id']) }} AS coupons_key,
        coupon_id AS coupons_id,
        
        -- Attributes
        coupon_code,
        promotion_id,
        usage_limit,
        usage_count,
        is_active,
        expires_at,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE coupon_id IS NOT NULL
)

SELECT * FROM final
