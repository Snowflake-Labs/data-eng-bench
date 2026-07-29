{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMERS') }}

),

deduplicated AS (
    SELECT
        CUSTOMER_ID,
        CUSTOMER_NUMBER,
        CUSTOMER_TYPE,
        EMAIL,
        EMAIL_VERIFIED,
        PHONE_PRIMARY,
        PHONE_VERIFIED,
        FIRST_NAME,
        LAST_NAME,
        MIDDLE_NAME,
        COMPANY_NAME,
        DATE_OF_BIRTH,
        GENDER,
        PREFERRED_LANGUAGE,
        PREFERRED_CURRENCY,
        TIMEZONE,
        TAX_EXEMPT,
        TAX_EXEMPT_ID,
        ACQUISITION_SOURCE,
        ACQUISITION_CAMPAIGN,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TAX_EXEMPT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
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
    FROM deduplicated
    WHERE TAX_EXEMPT_ID IS NOT NULL
)

SELECT * FROM renamed
