{{
    config(
        materialized='view',

        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('analytics', 'DIM_TIME') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TIME_KEY AS time_key,
        FULL_TIME AS full_time,
        COALESCE(HOUR, 0) AS hour,
        COALESCE(MINUTE, 0) AS minute,
        COALESCE(SECOND, 0) AS second,
        TRIM(AM_PM) AS am_pm,
        COALESCE(HOUR_12, 0) AS hour_12,
        TRIM(TIME_OF_DAY) AS time_of_day
    FROM cleaned
    WHERE TIME_KEY IS NOT NULL
)

SELECT * FROM renamed
