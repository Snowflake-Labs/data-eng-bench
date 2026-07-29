-- Shopping Cart Analysis
-- Analyzes shopping carts

with shopping_carts as (
    select * from {{ ref('stg_digital__shopping_carts') }}
),

shopping_cart_items as (
    select * from {{ ref('stg_digital__shopping_cart_items') }}
)

select
    sc.status,
    count(distinct sc.cart_id) as cart_count,
    count(distinct sc.customer_id) as unique_customers,
    sum(sc.item_count) as total_items,
    sum(sc.subtotal) as total_value,
    avg(sc.subtotal) as avg_cart_value,
    sum(case when sc.order_id is not null then 1 else 0 end) as converted_carts
from shopping_carts sc
left join shopping_cart_items sci on sc.cart_id = sci.cart_id
group by 1
