{{
    config(
        materialized='table',
        tags=['dimension', 'payments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_order_payments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['payment_id']) }} AS payments_key,
        payment_id AS payments_id,
        
        -- Attributes
        order_id,
        payment_method_id,
        payment_method,
        amount,
        currency_code,
        status,
        transaction_id,
        authorization_code,
        card_last_four,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE payment_id IS NOT NULL
)

SELECT * FROM final
