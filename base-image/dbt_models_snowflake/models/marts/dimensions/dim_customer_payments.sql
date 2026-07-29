{{
    config(
        materialized='table',
        tags=['dimension', 'payments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_payments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['payment_id']) }} AS payments_key,
        payment_id AS payments_id,

        -- Attributes
        payment_number,
        customer_id,
        payment_date,
        amount,
        payment_method,
        reference_number,
        status,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE payment_id IS NOT NULL
)

SELECT * FROM final
