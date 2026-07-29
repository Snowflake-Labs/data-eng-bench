{{
    config(
        materialized='view',
        unique_key='warehouse_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'T001W_HIST') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY WAREHOUSE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(WAREHOUSE_CODE) AS warehouse_code,
        TRIM(WAREHOUSE_NAME) AS warehouse_name,
        TRIM(WAREHOUSE_TYPE) AS warehouse_type,
        TRIM(ADDRESS_LINE_1) AS address_line_1,
        TRIM(CITY) AS city,
        TRIM(STATE_PROVINCE) AS state_province,
        TRIM(POSTAL_CODE) AS postal_code,
        TRIM(COUNTRY_CODE) AS country_code,
        LATITUDE AS latitude,
        LONGITUDE AS longitude,
        TRIM(TIMEZONE) AS timezone,
        TRIM(PHONE) AS phone,
        TRIM(EMAIL) AS email,
        TRIM(MANAGER_NAME) AS manager_name,
        COALESCE(SQUARE_FOOTAGE, 0) AS square_footage,
        COALESCE(MAX_CAPACITY_UNITS, 0) AS max_capacity_units,
        OPENED_DATE AS opened_date,
        COALESCE(PRIORITY, 0) AS priority,
        IS_ACTIVE AS is_active
    FROM deduplicated
    WHERE WAREHOUSE_ID IS NOT NULL
)

SELECT * FROM renamed
