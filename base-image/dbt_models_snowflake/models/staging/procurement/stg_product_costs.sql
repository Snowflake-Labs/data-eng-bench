{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_COSTS') }}

),

deduplicated AS (
    SELECT
        COST_ID,
        VARIANT_ID,
        SUPPLIER_ID,
        COST_TYPE,
        UNIT_COST,
        CURRENCY_CODE,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        created_at,
        ROW_NUMBER() OVER (PARTITION BY COST_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        COST_ID,
        VARIANT_ID,
        SUPPLIER_ID,
        COST_TYPE,
        UNIT_COST,
        CURRENCY_CODE,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        created_at
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(COST_ID) AS cost_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(COST_TYPE) AS cost_type,
        UNIT_COST AS unit_cost,
        TRIM(CURRENCY_CODE) AS currency_code,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE COST_ID IS NOT NULL
)

SELECT * FROM renamed
