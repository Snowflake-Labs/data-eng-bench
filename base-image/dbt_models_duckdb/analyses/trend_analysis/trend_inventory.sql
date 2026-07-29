-- Inventory Level Trend Analysis

with daily_inventory as (
    select
        movement_date,
        sum(case when movement_type = 'Receipt' then quantity_change else 0 end) as receipts,
        sum(case when movement_type = 'Sale' then abs(quantity_change) else 0 end) as sales,
        sum(quantity_change) as net_change
    from {{ ref('stg_wms__movements') }}
    group by movement_date
),

running_inventory as (
    select
        movement_date,
        receipts,
        sales,
        net_change,
        sum(net_change) over (order by movement_date) as running_inventory_level,
        round(avg(receipts::decimal) over (order by movement_date rows between 6 preceding and current row), 1) as moving_avg_receipts_7d,
        round(avg(sales::decimal) over (order by movement_date rows between 6 preceding and current row), 1) as moving_avg_sales_7d
    from daily_inventory
)

select * from running_inventory
order by movement_date desc
limit 90
