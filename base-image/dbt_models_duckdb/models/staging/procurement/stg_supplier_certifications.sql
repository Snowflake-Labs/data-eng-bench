{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SUPPLIER_CERTIFICATIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CERTIFICATION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CERTIFICATION_ID) AS certification_id,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(CERTIFICATION_TYPE) AS certification_type,
        TRIM(CERTIFICATION_NAME) AS certification_name,
        TRIM(ISSUED_BY) AS issued_by,
        ISSUE_DATE AS issue_date,
        EXPIRY_DATE AS expiry_date,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE CERTIFICATION_ID IS NOT NULL
)

SELECT * FROM renamed
