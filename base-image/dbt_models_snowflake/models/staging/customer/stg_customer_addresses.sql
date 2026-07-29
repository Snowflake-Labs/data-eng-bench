{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_ADDRESSES') }}

),

deduplicated AS (
    SELECT
        ADDRESS_ID,
        CUSTOMER_ID,
        ADDRESS_TYPE,
        ADDRESS_LABEL,
        IS_DEFAULT_BILLING,
        IS_DEFAULT_SHIPPING,
        RECIPIENT_NAME,
        COMPANY_NAME,
        ADDRESS_LINE_1,
        ADDRESS_LINE_2,
        ADDRESS_LINE_3,
        CITY,
        STATE_PROVINCE,
        POSTAL_CODE,
        COUNTRY_CODE,
        PHONE,
        DELIVERY_INSTRUCTIONS,
        LATITUDE,
        LONGITUDE,
        IS_VERIFIED,
        updated_at,
        created_at
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ADDRESS_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(ADDRESS_ID) AS address_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(ADDRESS_TYPE) AS address_type,
        TRIM(ADDRESS_LABEL) AS address_label, IS_DEFAULT_BILLING as is_default_billing,
        IS_DEFAULT_SHIPPING as is_default_shipping,
        TRIM(RECIPIENT_NAME) AS recipient_name,
        TRIM(COMPANY_NAME) AS company_name,
        TRIM(ADDRESS_LINE_1) AS address_line_1,
        TRIM(ADDRESS_LINE_2) AS address_line_2,
        TRIM(ADDRESS_LINE_3) AS address_line_3,
        TRIM(CITY) AS city,
        TRIM(STATE_PROVINCE) AS state_province,
        trim(POSTAL_CODE) as postal_code,
        TRIM(COUNTRY_CODE) AS country_code,
        TRIM(PHONE) AS phone,
        TRIM(DELIVERY_INSTRUCTIONS) AS delivery_instructions,
        COALESCE(LATITUDE, 0) as latitude,
        COALESCE(LONGITUDE, 0) as longitude, IS_VERIFIED as is_verified
    FROM deduplicated
    WHERE ADDRESS_ID IS NOT NULL
)

SELECT * FROM renamed
