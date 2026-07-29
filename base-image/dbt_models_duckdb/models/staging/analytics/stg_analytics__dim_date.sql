{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.DIM_DATE

with source as (
    select * from {{ source('analytics', 'DIM_DATE') }}
),

renamed as (
    select
        date_key,
        full_date,
        day_of_week,
        trim(day_name) as day_name,
        day_of_month,
        day_of_year,
        week_of_year,
        month_number,
        trim(month_name) as month_name,
        quarter,
        year,
        is_weekend,
        is_holiday,
        fiscal_year,
        fiscal_quarter
    from source
)

select * from renamed
