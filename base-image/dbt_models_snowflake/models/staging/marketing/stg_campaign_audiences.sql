{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'CAMPAIGN_AUDIENCES') }}

),

deduplicated AS (
    SELECT
        AUDIENCE_ID,
        CAMPAIGN_ID,
        SEGMENT_ID,
        AUDIENCE_NAME,
        AUDIENCE_SIZE,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY AUDIENCE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        AUDIENCE_ID,
        CAMPAIGN_ID,
        SEGMENT_ID,
        AUDIENCE_NAME,
        AUDIENCE_SIZE,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(AUDIENCE_ID) AS audience_id,
        TRIM(CAMPAIGN_ID) AS campaign_id,
        TRIM(SEGMENT_ID) AS segment_id,
        TRIM(AUDIENCE_NAME) AS audience_name,
        COALESCE(AUDIENCE_SIZE, 0) AS audience_size,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE AUDIENCE_ID IS NOT NULL
)

SELECT * FROM renamed
