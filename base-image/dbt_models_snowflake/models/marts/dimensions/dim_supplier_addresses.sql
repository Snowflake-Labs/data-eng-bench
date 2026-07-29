{{
    config(
        materialized='table',
        tags=['dimension', 'addresses', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_supplier_addresses') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['address_id']) }} AS addresses_key,
        address_id AS addresses_id,

        -- Attributes
        supplier_id,
        address_type,
        address_line_1,
        city,
        state_province,
        postal_code,
        country_code,
        is_primary,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE address_id IS NOT NULL
)

SELECT * FROM final
