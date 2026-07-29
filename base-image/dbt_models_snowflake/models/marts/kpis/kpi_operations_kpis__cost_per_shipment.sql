{{
    config(
        materialized='view',
        tags=['kpi', 'operations_kpis']
    )
}}

with shipments as (
    select
        shipment_id,
        shipping_cost,
        carrier_id
    from {{ ref('stg_orders__shipments') }}
    where shipping_cost is not null
        and shipping_cost > 0
)

select
    'Cost Per Shipment' as kpi_name,
    current_date as period,
    round(avg(shipping_cost), 2) as avg_cost_per_shipment,
    round(sum(shipping_cost), 2) as total_shipping_cost,
    count(*) as shipment_count,
    current_timestamp as dbt_updated_at
from shipments
