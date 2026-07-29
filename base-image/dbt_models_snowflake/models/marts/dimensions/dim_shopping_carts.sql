{{
    config(
        materialized='table',
        tags=['dimension', 'carts', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_shopping_carts') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['cart_id']) }} AS carts_key,
        cart_id AS carts_id,

        -- Attributes
        session_id,
        customer_id,
        channel_id,
        status,
        item_count,
        subtotal,
        created_at,
        updated_at,
        converted_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE cart_id IS NOT NULL
)

SELECT * FROM final
