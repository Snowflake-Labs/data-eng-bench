{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SUPPLIER_CONTACTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CONTACT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CONTACT_ID) AS contact_id,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(CONTACT_NAME) AS contact_name,
        TRIM(CONTACT_TYPE) AS contact_type,
        TRIM(EMAIL) AS email,
        TRIM(PHONE) AS phone,
        IS_PRIMARY AS is_primary,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CONTACT_ID IS NOT NULL
)

SELECT * FROM renamed
