{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('reference', 'UNITS_OF_MEASURE') }}

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
    FROM source
    WHERE UOM_CODE IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY UOM_CODE ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
)

SELECT * FROM renamed
