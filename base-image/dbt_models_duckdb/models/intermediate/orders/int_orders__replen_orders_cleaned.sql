{{
    config(
        materialized='view',
        tags=['intermediate', 'orders']
    )
}}

/*
    Intermediate model: int_orders__replen_orders_cleaned
    Domain: orders

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_wms__replen_orders') }}

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
