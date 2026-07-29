{{
    config(
        materialized='view',
        unique_key='address_id',
        tags=['staging', 'raw_sfdc', 'scaled']
    )
}}

-- stg_addresses
-- Customer address staging from enterprise DB
-- Note: Addresses can change frequently - customer updates, moves, corrections

-- HACK: Using ROW_NUMBER dedup because source has dirty data (multiple records per address_id)
-- The source team says they'll fix it "next quarter" - they said that last quarter too
-- FIXME: COALESCE(lat/lon, 0) is wrong - 0,0 is a real location (off Africa). Use NULL instead.
-- TODO: Add address standardization using SmartyStreets or Google Places API

WITH source AS (
    SELECT * FROM {{ source('raw_sfdc', 'addresses') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ADDRESS_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(ADDRESS_ID) AS address_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(ADDRESS_TYPE) AS address_type,
        TRIM(ADDRESS_LABEL) AS address_label,
        IS_DEFAULT_BILLING AS is_default_billing,
        IS_DEFAULT_SHIPPING AS is_default_shipping,
        TRIM(RECIPIENT_NAME) AS recipient_name,
        TRIM(COMPANY_NAME) AS company_name,
        TRIM(ADDRESS_LINE_1) AS address_line_1,
        TRIM(ADDRESS_LINE_2) AS address_line_2,
        TRIM(ADDRESS_LINE_3) AS address_line_3,
        TRIM(CITY) AS city,
        TRIM(STATE_PROVINCE) AS state_province,
        TRIM(POSTAL_CODE) AS postal_code,
        TRIM(COUNTRY_CODE) AS country_code,
        TRIM(PHONE) AS phone,
        TRIM(DELIVERY_INSTRUCTIONS) AS delivery_instructions,
        COALESCE(LATITUDE, 0) as latitude,
        COALESCE(LONGITUDE, 0) as longitude,
        IS_VERIFIED as is_verified
    FROM cleaned
    WHERE ADDRESS_ID IS NOT NULL
)

SELECT * FROM renamed
