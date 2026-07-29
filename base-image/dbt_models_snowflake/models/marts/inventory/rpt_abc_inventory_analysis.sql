with product_value as (
    select
        product_id,
        sum(quantity_ordered * unit_price) as annual_consumption_value
    from {{ ref('stg_orders__order_lines') }}
    group by 1
),
total_value as (
    select sum(annual_consumption_value) as total_val from product_value
),
ranked as (
    select
        pv.product_id,
        pv.annual_consumption_value,
        sum(pv.annual_consumption_value) over (order by pv.annual_consumption_value desc) as running_total
    from product_value pv
)

select
    r.product_id,
    r.annual_consumption_value,
    (r.running_total / t.total_val) as cumulative_pct,
    case
        when (r.running_total / t.total_val) <= 0.80 then 'A'
        when (r.running_total / t.total_val) <= 0.95 then 'B'
        else 'C'
    end as abc_class
from ranked r
cross join total_value t
