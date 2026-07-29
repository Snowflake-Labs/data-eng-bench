{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_COUNTS') }}

),

cleaned AS (
    SELECT
        COUNT_ID,
        COUNT_NUMBER,
        WAREHOUSE_ID,
        COUNT_TYPE,
        STATUS,
        SCHEDULED_DATE,
        TOTAL_LOCATIONS,
        TOTAL_SKUS,
        TOTAL_UNITS_COUNTED,
        TOTAL_VARIANCE_UNITS,
        TOTAL_VARIANCE_VALUE,
        CREATED_BY,
        created_at,
        updated_at
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY COUNT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
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
        created_at AS created_at,
        updated_at AS updated_at
    FROM cleaned
    WHERE COUNT_ID IS NOT NULL
)

SELECT * FROM renamed
