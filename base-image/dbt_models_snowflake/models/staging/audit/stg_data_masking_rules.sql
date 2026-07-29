{{
    config(
        materialized='view',

        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('audit', 'DATA_MASKING_RULES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY RULE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        RULE_ID,
        TABLE_NAME,
        COLUMN_NAME,
        MASKING_TYPE,
        IS_ACTIVE,
        CREATED_AT
    FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RULE_ID) AS rule_id,
        TRIM(TABLE_NAME) AS table_name,
        TRIM(COLUMN_NAME) AS column_name,
        TRIM(MASKING_TYPE) AS masking_type,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RULE_ID IS NOT NULL
)

SELECT * FROM renamed
