-- Customer Age Demographics
-- Customer age demographics

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

select
    case 
        when date_part('year', age(current_date, c.date_of_birth)) < 18 then 'Under 18'
        when date_part('year', age(current_date, c.date_of_birth)) between 18 and 24 then '18-24'
        when date_part('year', age(current_date, c.date_of_birth)) between 25 and 34 then '25-34'
        when date_part('year', age(current_date, c.date_of_birth)) between 35 and 44 then '35-44'
        when date_part('year', age(current_date, c.date_of_birth)) between 45 and 54 then '45-54'
        when date_part('year', age(current_date, c.date_of_birth)) between 55 and 64 then '55-64'
        else '65+'
    end as age_group,
    count(distinct c.customer_id) as customer_count,
    count(distinct o.order_id) as order_count,
    sum(ol.line_total - ol.discount_amount) as total_revenue,
    avg(ol.line_total - ol.discount_amount) as avg_order_value
from customers c
left join orders o on c.customer_id = o.customer_id
left join order_lines ol on o.order_id = ol.order_id
where c.date_of_birth is not null
group by 1