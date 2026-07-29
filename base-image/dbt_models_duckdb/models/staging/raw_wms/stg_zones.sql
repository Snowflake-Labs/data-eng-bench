{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_wms', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ZONES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ZONE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ZONE_ID) AS zone_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(ZONE_CODE) AS zone_code,
        TRIM(ZONE_NAME) AS zone_name,
        TRIM(ZONE_TYPE) AS zone_type,
        TRIM(TEMPERATURE_CONTROLLED) AS temperature_controlled,
        MIN_TEMPERATURE AS min_temperature,
        MAX_TEMPERATURE AS max_temperature,
        COALESCE(CAPACITY_UNITS, 0) AS capacity_units,
        COALESCE(SORT_ORDER, 0) AS sort_order,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE ZONE_ID IS NOT NULL
)

SELECT * FROM renamed
