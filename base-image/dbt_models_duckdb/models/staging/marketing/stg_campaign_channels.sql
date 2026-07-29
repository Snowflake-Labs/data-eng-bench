{{
    config(
        materialized='view',
        
        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CAMPAIGN_CHANNELS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CHANNEL_MAPPING_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CHANNEL_MAPPING_ID) AS channel_mapping_id,
        TRIM(CAMPAIGN_ID) AS campaign_id,
        TRIM(CHANNEL_TYPE) AS channel_type,
        COALESCE(ALLOCATED_BUDGET, 0) AS allocated_budget,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE CHANNEL_MAPPING_ID IS NOT NULL
)

SELECT * FROM renamed
