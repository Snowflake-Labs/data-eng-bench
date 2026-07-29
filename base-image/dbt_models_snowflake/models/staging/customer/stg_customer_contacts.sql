{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_CONTACTS') }}

),

deduplicated AS (
    SELECT
        CONTACT_ID,
        CUSTOMER_ID,
        CONTACT_TYPE,
        CONTACT_SUBTYPE,
        CONTACT_VALUE,
        IS_PRIMARY,
        IS_VERIFIED,
        VERIFIED_AT,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CONTACT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(CONTACT_ID) AS contact_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CONTACT_TYPE) AS contact_type,
        TRIM(CONTACT_SUBTYPE) AS contact_subtype,
        TRIM(CONTACT_VALUE) AS contact_value,
        IS_PRIMARY AS is_primary,
        IS_VERIFIED as is_verified,
        VERIFIED_AT as verified_at,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE CONTACT_ID IS NOT NULL
)

SELECT * FROM renamed
