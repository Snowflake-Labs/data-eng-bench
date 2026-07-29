{{
    config(
        materialized='view',
        
        tags=['staging', 'hr', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PAYROLL_DETAILS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY DETAIL_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(DETAIL_ID) AS detail_id,
        TRIM(PAYROLL_RUN_ID) AS payroll_run_id,
        TRIM(EMPLOYEE_ID) AS employee_id,
        COALESCE(GROSS_PAY, 0) AS gross_pay,
        COALESCE(TAX_DEDUCTIONS, 0) AS tax_deductions,
        COALESCE(OTHER_DEDUCTIONS, 0) AS other_deductions,
        COALESCE(NET_PAY, 0) AS net_pay,
        COALESCE(HOURS_WORKED, 0) AS hours_worked,
        COALESCE(OVERTIME_HOURS, 0) AS overtime_hours,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE DETAIL_ID IS NOT NULL
)

SELECT * FROM renamed
