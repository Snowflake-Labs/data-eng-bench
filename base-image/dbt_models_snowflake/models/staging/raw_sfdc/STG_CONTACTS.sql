{{
    config(
        materialized='view',
        unique_key='contact_id',
        tags=['staging', 'raw_sfdc', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_sfdc', 'contacts') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CONTACT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT *
    FROM deduplicated
    WHERE row_num = 1
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
        IS_VERIFIED AS is_verified,
        VERIFIED_AT as verified_at,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        trim(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM deduplicated
    WHERE row_num = 1
      AND CONTACT_ID IS NOT NULL
)

SELECT * FROM renamed
