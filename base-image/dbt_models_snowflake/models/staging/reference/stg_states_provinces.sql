{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('reference', 'STATES_PROVINCES') }}

),

renamed AS (
    SELECT
        TRIM(STATE_PROVINCE_ID) AS state_province_id,
        TRIM(COUNTRY_ID) AS country_id,
        TRIM(STATE_CODE) AS state_code,
        TRIM(STATE_NAME) AS state_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM source
    WHERE STATE_PROVINCE_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY STATE_PROVINCE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
)

SELECT * FROM renamed
