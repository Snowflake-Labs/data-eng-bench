{{
    config(
        materialized='table',
        tags=['dimension', 'categories', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_categories') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['category_id']) }} AS categories_key,
        category_id AS categories_id,

        -- Attributes
        category_code,
        category_name,
        category_description,
        parent_category_id,
        category_level,
        category_path,
        category_path_ids,
        sort_order,
        image_url,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE category_id IS NOT NULL
)

SELECT * FROM final
