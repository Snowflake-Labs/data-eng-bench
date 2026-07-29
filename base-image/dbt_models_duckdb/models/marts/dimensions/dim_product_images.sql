{{
    config(
        materialized='table',
        tags=['dimension', 'images', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_images') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['image_id']) }} AS images_key,
        image_id AS images_id,
        
        -- Attributes
        product_id,
        variant_id,
        image_url,
        thumbnail_url,
        alt_text,
        image_type,
        sort_order,
        width,
        height,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE image_id IS NOT NULL
)

SELECT * FROM final
