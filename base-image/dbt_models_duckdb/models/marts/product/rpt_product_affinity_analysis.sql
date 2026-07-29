with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
)

-- Which products appear in the same order
select 
    a.product_id as product_a,
    b.product_id as product_b,
    count(distinct a.order_id) as shared_orders,
    row_number() over (partition by a.product_id order by count(distinct a.order_id) desc) as rank
from order_lines a
join order_lines b on a.order_id = b.order_id and a.product_id != b.product_id
group by 1,2
having count(distinct a.order_id) > 5