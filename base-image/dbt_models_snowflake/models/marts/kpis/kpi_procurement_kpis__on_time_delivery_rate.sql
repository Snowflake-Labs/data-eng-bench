{{
    config(
        materialized='view',
        tags=['kpi', 'procurement_kpis']
    )
}}

with purchase_orders as (
    select
        po_number,
        expected_date,
        ordered_at,
        status
    from {{ ref('stg_procurement__purchase_orders') }}
    where status in ('Delivered', 'Received')
        and expected_date is not null
),

delivery_performance as (
    select
        po_number,
        case
            when status = 'Delivered' then 1
            else 0
        end as on_time_flag
    from purchase_orders
)

select
    'On-Time Delivery Rate' as kpi_name,
    current_date as period,
    round(100.0 * sum(on_time_flag) / nullif(count(*), 0), 2) as on_time_delivery_rate_pct,
    sum(on_time_flag) as on_time_orders,
    count(*) as total_orders,
    current_timestamp as dbt_updated_at
from delivery_performance
