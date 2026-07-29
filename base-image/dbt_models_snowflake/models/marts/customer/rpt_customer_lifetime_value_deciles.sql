with completed_orders as (
    select *
    from {{ ref('stg_orders__orders') }}
    where customer_id is not null
        and grand_total is not null
        and grand_total > 0
        and status in ('SHIPPED','PROCESSING','COMPLETED','CONFIRMED','DELIVERED','CANCELLED')
    ),

customer_aggregates as (
    select
        customer_id,
        count(distinct order_id) as order_count,
        sum(grand_total) as ltv,
        avg(grand_total) as avg_order_value,
        max(grand_total) as max_order_value,
        min(ordered_at) as first_order_date,
        max(ordered_at) as last_order_date
    from completed_orders
    group by customer_id
),

ranked_customers as (
    select
        agg.*,
        ntile(10) over (order by agg.ltv desc) as ltv_decile,
        row_number() over (order by agg.ltv desc) as ltv_rank,
        avg(agg.ltv) over () as avg_ltv,
        max(agg.ltv) over () as best_ltv
    from customer_aggregates agg
)

select
    customer_id,
    ltv,
    ltv_decile,
    ltv_rank,
    avg_ltv,
    best_ltv,
    ltv - avg_ltv as ltv_vs_avg,
    case when avg_ltv = 0 then null else (ltv - avg_ltv) / avg_ltv end as pct_vs_avg,
    order_count,
    avg_order_value,
    max_order_value,
    first_order_date,
    last_order_date,
    DATEDIFF(day, last_order_date, LOCALTIMESTAMP()) as days_since_last_order
from ranked_customers
order by customer_id
