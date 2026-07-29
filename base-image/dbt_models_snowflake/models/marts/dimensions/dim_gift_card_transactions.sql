{{
    config(
        materialized='table',
        tags=['dimension', 'transactions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_gift_card_transactions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['transaction_id']) }} AS transactions_key,
        transaction_id AS transactions_id,

        -- Attributes
        gift_card_id,
        transaction_type,
        amount,
        balance_after,
        order_id,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE transaction_id IS NOT NULL
)

SELECT * FROM final
