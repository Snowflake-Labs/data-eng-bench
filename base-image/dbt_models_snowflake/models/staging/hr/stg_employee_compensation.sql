{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'EMPLOYEE_COMPENSATION') }}

),

cleaned AS (
    SELECT
        COMPENSATION_ID,
        EMPLOYEE_ID,
        COMPENSATION_TYPE,
        AMOUNT,
        CURRENCY_CODE,
        FREQUENCY,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY COMPENSATION_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(COMPENSATION_ID) AS compensation_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        TRIM(COMPENSATION_TYPE) AS compensation_type,
        AMOUNT AS amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(FREQUENCY) AS frequency,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE COMPENSATION_ID IS NOT NULL
)

SELECT * FROM renamed
