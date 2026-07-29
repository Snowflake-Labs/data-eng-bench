{{
    config(
        materialized='table',
        tags=['dimension', 'addresses', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_addresses') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['address_id']) }} AS addresses_key,
        address_id AS addresses_id,

        -- Attributes
        customer_id,
        address_type,
        address_label,
        is_default_billing,
        is_default_shipping,
        recipient_name,
        company_name,
        address_line_1,
        address_line_2,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE address_id IS NOT NULL
)

SELECT * FROM final
