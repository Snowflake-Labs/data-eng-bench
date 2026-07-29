{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('reference', 'COUNTRIES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY COUNTRY_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT * FROM deduplicated
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
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE COUNTRY_ID IS NOT NULL
)

SELECT * FROM renamed
