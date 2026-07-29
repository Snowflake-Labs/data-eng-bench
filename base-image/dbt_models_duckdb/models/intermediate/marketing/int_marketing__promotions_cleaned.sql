{{
    config(
        materialized='view',
        tags=['intermediate', 'marketing']
    )
}}

/*
    Intermediate model: int_marketing__promotions_cleaned
    Domain: marketing

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_pos__promotions') }}

),

cleaned AS (

    SELECT
        promotion_id,
        promotion_code,
        promotion_name,
        promotion_type,
        discount_type,
        discount_value,
        min_purchase,
        max_discount,
        start_date,
        end_date,
        is_active,
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
