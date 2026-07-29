{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'GL_PERIODS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PERIOD_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PERIOD_ID) AS period_id,
        FISCAL_YEAR AS fiscal_year,
        FISCAL_QUARTER AS fiscal_quarter,
        FISCAL_MONTH AS fiscal_month,
        TRIM(PERIOD_NAME) AS period_name,
        START_DATE AS start_date,
        END_DATE AS end_date,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PERIOD_ID IS NOT NULL
)

SELECT * FROM renamed
