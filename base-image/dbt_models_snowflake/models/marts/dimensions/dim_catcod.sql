{{
    config(
        materialized='table',
        tags=['dimension', 'catcod', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_catcod') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['category_id']) }} AS catcod_key,
        category_id AS catcod_id,

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
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE category_id IS NOT NULL
)

SELECT * FROM final
