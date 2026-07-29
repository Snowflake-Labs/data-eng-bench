{{
    config(
        materialized='table',
        tags=['dimension', 'items', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_wishlist_items') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['wishlist_item_id']) }} AS items_key,
        wishlist_item_id AS items_id,

        -- Attributes
        wishlist_id,
        variant_id,
        added_at,
        notes,
        priority,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE wishlist_item_id IS NOT NULL
)

SELECT * FROM final
