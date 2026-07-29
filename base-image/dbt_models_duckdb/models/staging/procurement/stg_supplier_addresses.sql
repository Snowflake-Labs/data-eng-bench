{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SUPPLIER_ADDRESSES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ADDRESS_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ADDRESS_ID) AS address_id,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(ADDRESS_TYPE) AS address_type,
        TRIM(ADDRESS_LINE_1) AS address_line_1,
        TRIM(CITY) AS city,
        TRIM(STATE_PROVINCE) AS state_province,
        TRIM(POSTAL_CODE) AS postal_code,
        TRIM(COUNTRY_CODE) AS country_code,
        IS_PRIMARY AS is_primary,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ADDRESS_ID IS NOT NULL
)

SELECT * FROM renamed
