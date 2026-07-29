{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'SUPPLIER_PERFORMANCE_SCORES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY SCORE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        SCORE_ID,
        SUPPLIER_ID,
        PERIOD_DATE,
        QUALITY_SCORE,
        DELIVERY_SCORE,
        PRICE_SCORE,
        SERVICE_SCORE,
        OVERALL_SCORE,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(SCORE_ID) AS score_id,
        TRIM(SUPPLIER_ID) AS supplier_id,
        PERIOD_DATE AS period_date,
        COALESCE(QUALITY_SCORE, 0) AS quality_score,
        COALESCE(DELIVERY_SCORE, 0) AS delivery_score,
        COALESCE(PRICE_SCORE, 0) AS price_score,
        COALESCE(SERVICE_SCORE, 0) AS service_score,
        COALESCE(OVERALL_SCORE, 0) AS overall_score,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE SCORE_ID IS NOT NULL
)

SELECT * FROM renamed
