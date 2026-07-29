{{
    config(
        materialized='view',
        
        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'COMPLIANCE_RULES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY RULE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RULE_ID) AS rule_id,
        TRIM(RULE_CODE) AS rule_code,
        TRIM(RULE_NAME) AS rule_name,
        TRIM(RULE_TYPE) AS rule_type,
        TRIM(DESCRIPTION) AS description,
        TRIM(SEVERITY) AS severity,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RULE_ID IS NOT NULL
)

SELECT * FROM renamed
