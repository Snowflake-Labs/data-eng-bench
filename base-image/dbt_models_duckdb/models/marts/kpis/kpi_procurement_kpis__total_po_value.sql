{{
    config(
        materialized='view',
        tags=['kpi', 'procurement_kpis']
    )
}}

with purchase_orders as (
    select
        po_number,
        total_amount,
        currency_code,
        status,
        ordered_at
    from {{ ref('stg_procurement__purchase_orders') }}
)

select
    'Total Purchase Order Value' as kpi_name,
    current_date as period,
    round(sum(total_amount), 2) as total_po_value,
    round(avg(total_amount), 2) as avg_po_value,
    count(distinct po_number) as total_po_count,
    count(distinct case when status = 'Delivered' then po_number end) as delivered_po_count,
    current_timestamp as dbt_updated_at
from purchase_orders
