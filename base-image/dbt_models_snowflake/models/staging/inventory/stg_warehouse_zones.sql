{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'WAREHOUSE_ZONES') }}

),

deduplicated AS (
    SELECT
        ZONE_ID,
        WAREHOUSE_ID,
        ZONE_CODE,
        ZONE_NAME,
        ZONE_TYPE,
        TEMPERATURE_CONTROLLED,
        MIN_TEMPERATURE,
        MAX_TEMPERATURE,
        CAPACITY_UNITS,
        SORT_ORDER,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ZONE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(ZONE_ID) AS zone_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(ZONE_CODE) AS zone_code,
        TRIM(ZONE_NAME) AS zone_name,
        TRIM(ZONE_TYPE) AS zone_type,
        TEMPERATURE_CONTROLLED AS temperature_controlled,
        MIN_TEMPERATURE AS min_temperature,
        MAX_TEMPERATURE AS max_temperature,
        COALESCE(CAPACITY_UNITS, 0) AS capacity_units,
        COALESCE(SORT_ORDER, 0) AS sort_order,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE ZONE_ID IS NOT NULL
)

SELECT * FROM renamed
