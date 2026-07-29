{{
    config(
        materialized='table',
        tags=['dimension', 'hist', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_coupons_hist') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['coupon_id']) }} AS hist_key,
        coupon_id AS hist_id,
        
        -- Attributes
        coupon_code,
        promotion_id,
        usage_limit,
        usage_count,
        is_active,
        expires_at,
        created_at,
        _loaded_at,
        _source_system,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE coupon_id IS NOT NULL
)

SELECT * FROM final
