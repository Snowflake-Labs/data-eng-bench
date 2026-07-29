{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'MARKETING_CAMPAIGNS') }}

),

deduplicated AS (
    SELECT
        CAMPAIGN_ID,
        CAMPAIGN_CODE,
        CAMPAIGN_NAME,
        CAMPAIGN_TYPE,
        START_DATE,
        END_DATE,
        BUDGET,
        STATUS,
        CREATED_AT,
        UPDATED_AT,
        ROW_NUMBER() OVER (PARTITION BY CAMPAIGN_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        CAMPAIGN_ID,
        CAMPAIGN_CODE,
        CAMPAIGN_NAME,
        CAMPAIGN_TYPE,
        START_DATE,
        END_DATE,
        BUDGET,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CAMPAIGN_ID) AS campaign_id,
        TRIM(CAMPAIGN_CODE) AS campaign_code,
        TRIM(CAMPAIGN_NAME) AS campaign_name,
        TRIM(CAMPAIGN_TYPE) AS campaign_type,
        START_DATE AS start_date,
        END_DATE AS end_date,
        COALESCE(BUDGET, 0) AS budget,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CAMPAIGN_ID IS NOT NULL
)

SELECT * FROM renamed
