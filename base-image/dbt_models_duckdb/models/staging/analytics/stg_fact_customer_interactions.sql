{{
    config(
        materialized='view',
        
        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'FACT_CUSTOMER_INTERACTIONS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(INTERACTION_KEY) AS interaction_key,
        DATE_KEY AS date_key,
        COALESCE(TIME_KEY, 0) AS time_key,
        COALESCE(CUSTOMER_KEY, 0) AS customer_key,
        COALESCE(EMPLOYEE_KEY, 0) AS employee_key,
        COALESCE(CHANNEL_KEY, 0) AS channel_key,
        TRIM(INTERACTION_TYPE) AS interaction_type,
        COALESCE(DURATION_SECONDS, 0) AS duration_seconds,
        COALESCE(SATISFACTION_SCORE, 0) AS satisfaction_score,
        RESOLVED AS resolved
    FROM cleaned
    WHERE INTERACTION_KEY IS NOT NULL
)

SELECT * FROM renamed
