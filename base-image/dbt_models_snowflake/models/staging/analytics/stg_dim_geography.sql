{{
    config(
        materialized='view',

        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('analytics', 'DIM_GEOGRAPHY') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        GEOGRAPHY_KEY AS geography_key,
        TRIM(COUNTRY_CODE) AS country_code,
        TRIM(COUNTRY_NAME) AS country_name,
        TRIM(STATE_CODE) AS state_code,
        TRIM(STATE_NAME) AS state_name,
        TRIM(CITY) AS city,
        TRIM(POSTAL_CODE) AS postal_code,
        TRIM(REGION) AS region,
        TRIM(TIMEZONE) AS timezone
    FROM cleaned
    WHERE GEOGRAPHY_KEY IS NOT NULL
)

SELECT * FROM renamed
