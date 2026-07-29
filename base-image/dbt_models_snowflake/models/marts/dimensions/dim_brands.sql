{{
    config(
        materialized='table',
        tags=['dimension', 'brands', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_brands') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['brand_id']) }} AS brands_key,
        brand_id AS brands_id,

        -- Attributes
        brand_code,
        brand_name,
        brand_description,
        brand_logo_url,
        brand_website,
        parent_brand_id,
        is_private_label,
        is_active,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE brand_id IS NOT NULL
)

SELECT * FROM final
