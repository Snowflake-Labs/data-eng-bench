{{
    config(
        materialized='table',
        tags=['dimension', 'prices', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_prices') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['price_id']) }} AS prices_key,
        price_id AS prices_id,
        
        -- Attributes
        variant_id,
        price_type,
        currency_code,
        price_amount,
        compare_at_price,
        cost_price,
        min_qty,
        max_qty,
        customer_tier_id,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE price_id IS NOT NULL
)

SELECT * FROM final
