/*
================================================================================
dim_products - Product Dimension
================================================================================
Master product dimension containing all product attributes.
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['dimension', 'product']
    )
}}

SELECT
    product_id,
    product_code AS sku,
    product_name,
    product_description,
    primary_category_id AS category_id,
    brand_id,
    MSRP AS unit_price,
    COST_PRICE AS cost_price,
    WEIGHT AS weight,
    LENGTH AS length,
    WIDTH AS width,
    HEIGHT AS height,
    IS_ACTIVE AS is_active,
    CREATED_AT AS created_at,
    UPDATED_AT AS updated_at,
    CURRENT_TIMESTAMP AS dbt_updated_at
FROM {{ ref('stg_product__products') }}
