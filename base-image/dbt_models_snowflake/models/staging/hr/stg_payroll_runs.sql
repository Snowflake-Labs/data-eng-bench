{{
    config(
        materialized='view',

        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('hr', 'PAYROLL_RUNS') }}

),

deduplicated AS (
    SELECT
        PAYROLL_RUN_ID,
        PAYROLL_PERIOD,
        PERIOD_START,
        PERIOD_END,
        PAY_DATE,
        STATUS,
        TOTAL_GROSS,
        TOTAL_NET,
        EMPLOYEE_COUNT,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY PAYROLL_RUN_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        PAYROLL_RUN_ID,
        PAYROLL_PERIOD,
        PERIOD_START,
        PERIOD_END,
        PAY_DATE,
        STATUS,
        TOTAL_GROSS,
        TOTAL_NET,
        EMPLOYEE_COUNT,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
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
