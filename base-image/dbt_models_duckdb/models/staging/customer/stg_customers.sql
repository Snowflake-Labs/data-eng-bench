{{
    config(
        materialized='view',
        
        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMERS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TAX_EXEMPT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CUSTOMER_NUMBER) AS customer_number,
        TRIM(CUSTOMER_TYPE) AS customer_type,
        TRIM(EMAIL) AS email,
        EMAIL_VERIFIED AS email_verified,
        TRIM(PHONE_PRIMARY) AS phone_primary,
        PHONE_VERIFIED AS phone_verified,
        TRIM(FIRST_NAME) AS first_name,
        TRIM(LAST_NAME) AS last_name,
        TRIM(MIDDLE_NAME) AS middle_name,
        TRIM(COMPANY_NAME) AS company_name,
        DATE_OF_BIRTH AS date_of_birth,
        TRIM(GENDER) AS gender,
        TRIM(PREFERRED_LANGUAGE) AS preferred_language,
        TRIM(PREFERRED_CURRENCY) AS preferred_currency,
        TRIM(TIMEZONE) AS timezone,
        TAX_EXEMPT AS tax_exempt,
        TRIM(TAX_EXEMPT_ID) AS tax_exempt_id,
        TRIM(ACQUISITION_SOURCE) AS acquisition_source,
        TRIM(ACQUISITION_CAMPAIGN) AS acquisition_campaign
    FROM cleaned
    WHERE TAX_EXEMPT_ID IS NOT NULL
)

SELECT * FROM renamed
