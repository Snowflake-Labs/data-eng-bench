{{
    config(
        materialized='view',
        unique_key='country_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'T005') }}

),

cleaned AS (
    SELECT
        COUNTRY_ID,
        COUNTRY_CODE_2,
        COUNTRY_NAME,
        CONTINENT,
        CURRENCY_CODE,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH
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
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE COUNTRY_ID IS NOT NULL
)

SELECT * FROM renamed
