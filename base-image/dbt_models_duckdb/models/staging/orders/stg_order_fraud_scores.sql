{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_FRAUD_SCORES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY FRAUD_SCORE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(FRAUD_SCORE_ID) AS fraud_score_id,
        TRIM(ORDER_ID) AS order_id,
        SCORE AS score,
        TRIM(RISK_LEVEL) AS risk_level,
        TRIM(PROVIDER) AS provider,
        RULE_HITS AS rule_hits,
        TRIM(IP_COUNTRY) AS ip_country,
        TRIM(REVIEWED_BY) AS reviewed_by,
        REVIEWED_AT AS reviewed_at,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE FRAUD_SCORE_ID IS NOT NULL
)

SELECT * FROM renamed
