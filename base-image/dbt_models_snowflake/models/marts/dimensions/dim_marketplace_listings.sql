{{
    config(
        materialized='table',
        tags=['dimension', 'listings', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_marketplace_listings') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['listing_id']) }} AS listings_key,
        listing_id AS listings_id,

        -- Attributes
        channel_id,
        product_id,
        variant_id,
        external_id,
        listing_title,
        listing_price,
        status,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE listing_id IS NOT NULL
)

SELECT * FROM final
