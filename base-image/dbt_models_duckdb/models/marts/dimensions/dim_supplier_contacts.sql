{{
    config(
        materialized='table',
        tags=['dimension', 'contacts', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_supplier_contacts') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['contact_id']) }} AS contacts_key,
        contact_id AS contacts_id,
        
        -- Attributes
        supplier_id,
        contact_name,
        contact_type,
        email,
        phone,
        is_primary,
        is_active,
        created_at,
        updated_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE contact_id IS NOT NULL
)

SELECT * FROM final
