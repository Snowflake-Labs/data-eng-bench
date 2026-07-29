{{
    config(
        materialized='view',
        tags=['time_series', 'finance', 'monthly']
    )
}}

-- Time series aggregation for finance revenue_recognized by monthly
-- Note: Customize this query based on your specific fact table

with base_data as (
    select
        current_date as event_date,
        1 as metric_value
    limit 0  -- Placeholder - replace with actual table
),

aggregated as (
    select
        date_trunc('month', event_date) as period_start,
        count(*) as record_count,
        sum(metric_value) as total_value,
        current_timestamp as dbt_updated_at
    from base_data
    group by date_trunc('month', event_date)
)

select * from aggregated
