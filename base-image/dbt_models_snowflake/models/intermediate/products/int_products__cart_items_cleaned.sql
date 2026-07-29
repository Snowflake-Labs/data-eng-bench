{{
    config(
        materialized='view',
        tags=['intermediate', 'products']
    )
}}

/*
    Intermediate model: int_products__cart_items_cleaned
    Domain: products

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_ga__cart_items') }}

),

cleaned AS (

    SELECT
        _id,
        _loaded_at,
        _source_system,
        _source_table,
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
