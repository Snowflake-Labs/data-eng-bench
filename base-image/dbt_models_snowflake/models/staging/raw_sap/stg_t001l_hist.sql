{{
    config(
        materialized='view',
        unique_key='location_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'T001L_HIST') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOCATION_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(LOCATION_ID) AS location_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(ZONE_ID) AS zone_id,
        TRIM(LOCATION_CODE) AS location_code,
        TRIM(LOCATION_BARCODE) AS location_barcode,
        TRIM(AISLE) AS aisle,
        TRIM(RACK) AS rack,
        TRIM(SHELF) AS shelf,
        TRIM(LOCATION_TYPE) AS location_type,
        IS_PICKABLE AS is_pickable,
        IS_RECEIVABLE AS is_receivable,
        MAX_WEIGHT AS max_weight,
        COALESCE(PICK_SEQUENCE, 0) AS pick_sequence,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number
    FROM deduplicated
    WHERE LOCATION_ID IS NOT NULL
)

SELECT * FROM renamed
