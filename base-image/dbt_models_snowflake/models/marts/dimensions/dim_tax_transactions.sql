{{
    config(
        materialized='table',
        tags=['dimension', 'transactions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_tax_transactions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['tax_transaction_id']) }} AS transactions_key,
        tax_transaction_id AS transactions_id,

        -- Attributes
        order_id,
        invoice_id,
        tax_rate_id,
        taxable_amount,
        tax_amount,
        tax_date,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE tax_transaction_id IS NOT NULL
)

SELECT * FROM final
