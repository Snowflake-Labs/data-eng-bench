{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('reference', 'REASON_CODES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY REASON_CODE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT * FROM deduplicated
    QUALIFY ROW_NUMBER() OVER (PARTITION BY REASON_CODE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(REASON_CODE_ID) AS reason_code_id,
        TRIM(ENTITY_TYPE) AS entity_type,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(REASON_NAME) AS reason_name,
        TRIM(REASON_DESCRIPTION) AS reason_description,
        REQUIRES_NOTES AS requires_notes,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE REASON_CODE_ID IS NOT NULL
)

SELECT * FROM renamed
