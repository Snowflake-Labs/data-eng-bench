{{
    config(
        materialized='table',
        tags=['dimension', 'items', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_shopping_cart_items') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['cart_item_id']) }} AS items_key,
        cart_item_id AS items_id,

        -- Attributes
        cart_id,
        variant_id,
        quantity,
        unit_price,
        line_total,
        added_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE cart_item_id IS NOT NULL
)

SELECT * FROM final
