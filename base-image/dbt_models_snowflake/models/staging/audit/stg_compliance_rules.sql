{{
    config(
        materialized='view',

        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('audit', 'COMPLIANCE_RULES') }}

),

cleaned AS (
    SELECT
        RULE_ID,
        RULE_CODE,
        RULE_NAME,
        RULE_TYPE,
        DESCRIPTION,
        SEVERITY,
        IS_ACTIVE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY RULE_ID ORDER BY created_at DESC NULLS LAST) = 1
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
