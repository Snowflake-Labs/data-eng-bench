{{
    config(
        materialized='view',

        tags=['staging', 'raw_wms', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_wms', 'cycle_counts') }}

),

renamed AS (
    SELECT
        TRIM(COUNT_ID) AS count_id,
        TRIM(COUNT_NUMBER) AS count_number,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(COUNT_TYPE) AS count_type,
        TRIM(STATUS) AS status,
        SCHEDULED_DATE AS scheduled_date,
        TRIM(TOTAL_LOCATIONS) AS total_locations,
        TRIM(TOTAL_SKUS) AS total_skus,
        TRIM(TOTAL_UNITS_COUNTED) AS total_units_counted,
        TRIM(TOTAL_VARIANCE_UNITS) AS total_variance_units,
        TRIM(TOTAL_VARIANCE_VALUE) AS total_variance_value,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM source
    WHERE COUNT_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY COUNT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
)

SELECT * FROM renamed
