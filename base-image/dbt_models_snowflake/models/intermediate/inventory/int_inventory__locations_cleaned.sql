{{
    config(
        materialized='view',
        tags=['intermediate', 'inventory']
    )
}}

/*
    Intermediate model: int_inventory__locations_cleaned
    Domain: inventory

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_wms__locations') }}

),

cleaned AS (

    SELECT
        location_id,
        warehouse_id,
        zone_id,
        location_code,
        location_barcode,
        aisle,
        rack,
        shelf,
        location_type,
        is_pickable,
        is_receivable,
        max_weight,
        pick_sequence,
        is_active,
        created_at,
        updated_at,
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
