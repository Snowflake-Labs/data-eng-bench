{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'STORES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY STORE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(STORE_ID) AS store_id,
        TRIM(STORE_NUMBER) AS store_number,
        TRIM(STORE_NAME) AS store_name,
        TRIM(STORE_TYPE) AS store_type,
        TRIM(STORE_FORMAT) AS store_format,
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
        COALESCE(SQUARE_FOOTAGE, 0) AS square_footage,
        OPENED_DATE AS opened_date,
        SUPPORTS_BOPIS AS supports_bopis,
        SUPPORTS_SHIP_FROM_STORE AS supports_ship_from_store,
        SUPPORTS_RETURNS AS supports_returns
    FROM cleaned
    WHERE STORE_ID IS NOT NULL
)

SELECT * FROM renamed
