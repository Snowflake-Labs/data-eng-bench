{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'PROMOTION_RULES') }}

),

deduplicated AS (
    SELECT
        RULE_ID,
        PROMOTION_ID,
        RULE_TYPE,
        RULE_OPERATOR,
        RULE_VALUE,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY RULE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        RULE_ID,
        PROMOTION_ID,
        RULE_TYPE,
        RULE_OPERATOR,
        RULE_VALUE,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RULE_ID) AS rule_id,
        TRIM(PROMOTION_ID) AS promotion_id,
        TRIM(RULE_TYPE) AS rule_type,
        TRIM(RULE_OPERATOR) AS rule_operator,
        TRIM(RULE_VALUE) AS rule_value,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RULE_ID IS NOT NULL
)

SELECT * FROM renamed
