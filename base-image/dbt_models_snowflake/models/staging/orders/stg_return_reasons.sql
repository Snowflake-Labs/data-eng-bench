{{
    config(
        materialized='view',

        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('orders', 'RETURN_REASONS') }}

),

cleaned AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY REASON_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(REASON_ID) AS reason_id,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(REASON_NAME) AS reason_name,
        TRIM(REASON_DESCRIPTION) AS reason_description,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE REASON_ID IS NOT NULL
)

SELECT * FROM renamed
