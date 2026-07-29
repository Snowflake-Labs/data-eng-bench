/*
================================================================================
BACKUP: Fiscal Calendar Dimension
================================================================================
Created during the Great Fiscal Calendar Incident of 2024.

What happened:
1. Someone changed fiscal year end date in dim_dates
2. All finance reports broke
3. We created this backup from production
4. Fixed the original
5. Forgot to delete the backup

This has been running for 8 months, duplicating dim_dates work.
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['backup', 'incident_response', 'redundant'],
        meta={
            'owner': 'data-eng@company.com',
            'created_during': 'INC-2024-0320 - Fiscal Calendar Incident',
            'purpose': 'Emergency backup, should be deleted',
            'duplicate_of': 'dim_dates'
        }
    )
}}

-- Emergency backup created 2024-03-20
-- Can be deleted - original dim_dates is fixed

SELECT
    date_key,
    full_date,
    day_of_week,
    day_of_month,
    day_of_year,
    week_of_year,
    month_number,
    month_name,
    quarter_number,
    year_number,

    -- Fiscal fields (these were broken, now fixed in dim_dates)
    fiscal_year,
    fiscal_quarter,
    fiscal_month,
    fiscal_week,

    is_weekend,
    is_holiday,
    holiday_name,

    'BACKUP_DO_NOT_USE' AS _warning

FROM {{ ref('dim_dates') }}
