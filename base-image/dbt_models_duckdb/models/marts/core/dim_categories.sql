/*
================================================================================
dim_categories - Product Category Dimension
================================================================================
Hierarchical product categories for retail classification.
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['dimension', 'product']
    )
}}

SELECT
    category_id,
    category_name,
    parent_category_id,
    category_level,
    category_path,
    is_active,
    created_at,
    updated_at,
    CURRENT_TIMESTAMP AS dbt_updated_at
FROM {{ ref('stg_product__product_categories') }}
