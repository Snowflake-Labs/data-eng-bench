{{
    config(
        materialized='view',
        
        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_TAGS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(TAG_ID) AS tag_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(TAG_NAME) AS tag_name,
        TRIM(TAG_CATEGORY) AS tag_category,
        TRIM(TAG_SOURCE) AS tag_source,
        APPLIED_AT AS applied_at,
        TRIM(APPLIED_BY) AS applied_by,
        EXPIRES_AT AS expires_at,
        IS_ACTIVE AS is_active
    FROM cleaned
    WHERE TAG_ID IS NOT NULL
)

SELECT * FROM renamed
