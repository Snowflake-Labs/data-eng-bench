{{
    config(
        materialized='table',
        tags=['dimension', 'transactions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_gl_transactions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['transaction_id']) }} AS transactions_key,
        transaction_id AS transactions_id,
        
        -- Attributes
        transaction_number,
        account_id,
        period_id,
        transaction_date,
        debit_amount,
        credit_amount,
        description,
        reference_type,
        reference_id,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE transaction_id IS NOT NULL
)

SELECT * FROM final
