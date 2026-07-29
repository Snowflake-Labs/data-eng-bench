{{
    config(
        materialized='view',
        tags=['kpi', 'procurement_kpis']
    )
}}

with purchase_orders as (
    select
        po_number,
        supplier_id,
        expected_date,
        ordered_at,
        status
    from {{ ref('stg_procurement__purchase_orders') }}
    where status in ('Delivered', 'Received')
        and expected_date is not null
        and ordered_at is not null
),

lead_times as (
    select
        po_number,
        supplier_id,
        date_diff('day', ordered_at, expected_date) as lead_time_days
    from purchase_orders
)

select
    'Average Lead Time' as kpi_name,
    current_date as period,
    round(avg(lead_time_days), 1) as avg_lead_time_days,
    min(lead_time_days) as min_lead_time_days,
    max(lead_time_days) as max_lead_time_days,
    count(*) as order_count,
    current_timestamp as dbt_updated_at
from lead_times
