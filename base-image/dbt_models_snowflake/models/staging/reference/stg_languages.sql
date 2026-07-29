{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('reference', 'LANGUAGES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY LANGUAGE_CODE ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT * FROM deduplicated
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LANGUAGE_CODE ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(LANGUAGE_CODE) AS language_code,
        TRIM(LANGUAGE_NAME) AS language_name,
        TRIM(NATIVE_NAME) AS native_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE LANGUAGE_CODE IS NOT NULL
)

SELECT * FROM renamed
