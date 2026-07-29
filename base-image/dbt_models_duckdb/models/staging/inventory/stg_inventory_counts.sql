{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_COUNTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY COUNT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(COUNT_ID) AS count_id,
        TRIM(COUNT_NUMBER) AS count_number,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(COUNT_TYPE) AS count_type,
        TRIM(STATUS) AS status,
        SCHEDULED_DATE AS scheduled_date,
        COALESCE(TOTAL_LOCATIONS, 0) AS total_locations,
        COALESCE(TOTAL_SKUS, 0) AS total_skus,
        COALESCE(TOTAL_UNITS_COUNTED, 0) AS total_units_counted,
        COALESCE(TOTAL_VARIANCE_UNITS, 0) AS total_variance_units,
        COALESCE(TOTAL_VARIANCE_VALUE, 0) AS total_variance_value,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE COUNT_ID IS NOT NULL
)

SELECT * FROM renamed
