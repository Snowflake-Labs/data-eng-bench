{{
    config(
        materialized='view',
        
        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'COMPLIANCE_VIOLATIONS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(VIOLATION_ID) AS violation_id,
        TRIM(RULE_ID) AS rule_id,
        DETECTED_AT AS detected_at,
        TRIM(ENTITY_TYPE) AS entity_type,
        TRIM(ENTITY_ID) AS entity_id,
        TRIM(DESCRIPTION) AS description,
        TRIM(SEVERITY) AS severity,
        TRIM(STATUS) AS status,
        TRIM(RESOLVED_BY) AS resolved_by,
        RESOLVED_AT AS resolved_at
    FROM cleaned
    WHERE VIOLATION_ID IS NOT NULL
)

SELECT * FROM renamed
