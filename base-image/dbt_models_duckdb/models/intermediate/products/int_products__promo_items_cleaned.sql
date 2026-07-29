{{
    config(
        materialized='view',
        tags=['intermediate', 'products']
    )
}}

/*
    Intermediate model: int_products__promo_items_cleaned
    Domain: products

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_sap__promo_items') }}

),

cleaned AS (

    SELECT
        mapping_id,
        promotion_id,
        product_id,
        category_id,
        brand_id,
        created_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
