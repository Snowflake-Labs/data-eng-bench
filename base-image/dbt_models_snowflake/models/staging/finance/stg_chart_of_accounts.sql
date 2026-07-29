{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CHART_OF_ACCOUNTS') }}

),

deduplicated AS (
    SELECT
        ACCOUNT_ID,
        ACCOUNT_NUMBER,
        ACCOUNT_NAME,
        ACCOUNT_TYPE,
        ACCOUNT_SUBTYPE,
        PARENT_ACCOUNT_ID,
        IS_ACTIVE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ACCOUNT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(ACCOUNT_ID) AS account_id,
        TRIM(ACCOUNT_NUMBER) AS account_number,
        TRIM(ACCOUNT_NAME) AS account_name,
        TRIM(ACCOUNT_TYPE) AS account_type,
        TRIM(ACCOUNT_SUBTYPE) AS account_subtype,
        TRIM(PARENT_ACCOUNT_ID) AS parent_account_id,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ACCOUNT_ID IS NOT NULL
)

SELECT * FROM renamed
