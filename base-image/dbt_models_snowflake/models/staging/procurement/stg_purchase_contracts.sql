{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'PURCHASE_CONTRACTS') }}

),

deduplicated AS (
    SELECT
        CONTRACT_ID,
        CONTRACT_NUMBER,
        SUPPLIER_ID,
        CONTRACT_TYPE,
        START_DATE,
        END_DATE,
        TOTAL_VALUE,
        STATUS,
        created_at,
        updated_at,
        ROW_NUMBER() OVER (PARTITION BY CONTRACT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        CONTRACT_ID,
        CONTRACT_NUMBER,
        SUPPLIER_ID,
        CONTRACT_TYPE,
        START_DATE,
        END_DATE,
        TOTAL_VALUE,
        STATUS,
        created_at,
        updated_at
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CONTRACT_ID) AS contract_id,
        TRIM(CONTRACT_NUMBER) AS contract_number,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(CONTRACT_TYPE) AS contract_type,
        START_DATE AS start_date,
        END_DATE AS end_date,
        COALESCE(TOTAL_VALUE, 0) AS total_value,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CONTRACT_ID IS NOT NULL
)

SELECT * FROM renamed
