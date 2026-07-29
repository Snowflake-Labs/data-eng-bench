{{
    config(
        materialized='view',
        
        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'UNITS_OF_MEASURE') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY UOM_CODE ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(UOM_CODE) AS uom_code,
        TRIM(UOM_NAME) AS uom_name,
        TRIM(UOM_TYPE) AS uom_type,
        TRIM(BASE_UOM_CODE) AS base_uom_code,
        CONVERSION_FACTOR AS conversion_factor,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE UOM_CODE IS NOT NULL
)

SELECT * FROM renamed
