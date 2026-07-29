{{
    config(
        materialized='table',
        tags=['dimension', 'suppliers', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_suppliers') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['supplier_id']) }} AS suppliers_key,
        supplier_id AS suppliers_id,

        -- Attributes
        supplier_code,
        supplier_name,
        supplier_type,
        tax_id,
        duns_number,
        payment_terms,
        currency_code,
        lead_time_days,
        min_order_value,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE supplier_id IS NOT NULL
)

SELECT * FROM final
