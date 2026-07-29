{{
    config(
        materialized='view',
        
        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PAYROLL_RUNS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PAYROLL_RUN_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PAYROLL_RUN_ID) AS payroll_run_id,
        TRIM(PAYROLL_PERIOD) AS payroll_period,
        PERIOD_START AS period_start,
        PERIOD_END AS period_end,
        PAY_DATE AS pay_date,
        TRIM(STATUS) AS status,
        COALESCE(TOTAL_GROSS, 0) AS total_gross,
        COALESCE(TOTAL_NET, 0) AS total_net,
        COALESCE(EMPLOYEE_COUNT, 0) AS employee_count,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PAYROLL_RUN_ID IS NOT NULL
)

SELECT * FROM renamed
