{{
    config(
        materialized='view',
        tags=['intermediate', 'web']
    )
}}

/*
    Intermediate model: int_web__events_cleaned
    Domain: web

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_ga__events') }}

),

cleaned AS (

    SELECT
        event_id,
        session_id,
        event_type,
        event_name,
        event_timestamp,
        page_url,
        element_id,
        element_class,
        product_id,
        event_value,
        event_data,
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
