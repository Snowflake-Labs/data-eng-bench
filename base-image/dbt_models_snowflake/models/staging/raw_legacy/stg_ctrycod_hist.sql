{{
    config(
        materialized='view',

        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_legacy', 'ctrycod_hist') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY COUNTRY_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(COUNTRY_ID) AS country_id,
        TRIM(COUNTRY_CODE_2) AS country_code_2,
        TRIM(COUNTRY_NAME) AS country_name,
        TRIM(CONTINENT) AS continent,
        TRIM(CURRENCY_CODE) AS currency_code,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM deduplicated
    WHERE COUNTRY_ID IS NOT NULL
)

SELECT * FROM renamed
