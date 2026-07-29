{{
    config(
        materialized='view',
        
        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'TIMEZONES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TIMEZONE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TIMEZONE_ID) AS timezone_id,
        TRIM(TIMEZONE_NAME) AS timezone_name,
        TRIM(UTC_OFFSET) AS utc_offset,
        USES_DST AS uses_dst,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE TIMEZONE_ID IS NOT NULL
)

SELECT * FROM renamed
