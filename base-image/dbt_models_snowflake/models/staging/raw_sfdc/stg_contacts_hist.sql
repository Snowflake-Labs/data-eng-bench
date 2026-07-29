{{
    config(
        materialized='view',
        unique_key='contact_id',
        tags=['staging', 'raw_sfdc', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_sfdc', 'contacts_hist') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CONTACT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
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
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH,
        "_archived_at",
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CONTACT_ID) AS contact_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CONTACT_TYPE) AS contact_type,
        TRIM(CONTACT_SUBTYPE) AS contact_subtype,
        TRIM(CONTACT_VALUE) AS contact_value,
        IS_PRIMARY AS is_primary,
        IS_VERIFIED AS is_verified,
        VERIFIED_AT AS verified_at,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        trim(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE CONTACT_ID IS NOT NULL
)

SELECT * FROM renamed
