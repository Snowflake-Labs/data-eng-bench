{{
    config(
        materialized='table',
        tags=['dimension', 'applications', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_payment_applications') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['application_id']) }} AS applications_key,
        application_id AS applications_id,
        
        -- Attributes
        payment_id,
        invoice_id,
        amount_applied,
        applied_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE application_id IS NOT NULL
)

SELECT * FROM final
