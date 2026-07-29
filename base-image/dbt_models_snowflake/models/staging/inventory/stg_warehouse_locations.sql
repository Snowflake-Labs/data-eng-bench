{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'WAREHOUSE_LOCATIONS') }}

),

deduplicated AS (
    SELECT
        LOCATION_ID,
        WAREHOUSE_ID,
        ZONE_ID,
        LOCATION_CODE,
        LOCATION_BARCODE,
        AISLE,
        RACK,
        SHELF,
        LOCATION_TYPE,
        IS_PICKABLE,
        IS_RECEIVABLE,
        MAX_WEIGHT,
        PICK_SEQUENCE,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LOCATION_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE LOCATION_ID IS NOT NULL
)

SELECT * FROM renamed
