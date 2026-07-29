-- Order Value Buckets
-- Segments orders by value

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    case 
        when grand_total < 50 then 'Under $50'
        when grand_total between 50 and 100 then '$50-$100'
        when grand_total between 100 and 200 then '$100-$200'
        when grand_total between 200 and 500 then '$200-$500'
        when grand_total between 500 and 1000 then '$500-$1000'
        else 'Over $1000'
    end as order_value_bucket,
    count(distinct order_id) as order_count,
    sum(grand_total) as total_revenue,
    count(distinct customer_id) as unique_customers,
    avg(grand_total) as avg_order_value
from orders
group by 1
