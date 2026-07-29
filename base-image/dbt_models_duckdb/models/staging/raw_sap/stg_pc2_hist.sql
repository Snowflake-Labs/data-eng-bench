{{
    config(
        materialized='view',
        unique_key='payroll_run_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PC2_HIST') }}
    
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
        TRIM(PERIOD_START) AS period_start,
        TRIM(PERIOD_END) AS period_end,
        PAY_DATE AS pay_date,
        TRIM(STATUS) AS status,
        TRIM(TOTAL_GROSS) AS total_gross,
        TRIM(TOTAL_NET) AS total_net,
        COALESCE(EMPLOYEE_COUNT, 0) AS employee_count,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        _archived_at AS _archived_at
    FROM cleaned
    WHERE PAYROLL_RUN_ID IS NOT NULL
)

SELECT * FROM renamed
