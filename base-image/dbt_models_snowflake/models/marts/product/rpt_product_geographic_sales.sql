-- Product Geographic Sales
-- Analyzes product sales by geography

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
)

select
    p.product_id,
    p.product_name,
    ca.country_code,
    count(distinct o.order_id) as order_count,
    sum(ol.quantity_ordered) as total_quantity,
    sum(ol.line_total) as total_revenue
from products p
left join product_variants pv on p.product_id = pv.product_id
left join order_lines ol on pv.variant_id = ol.variant_id
left join orders o on ol.order_id = o.order_id
left join customers c on o.customer_id = c.customer_id
left join customer_addresses ca on c.customer_id = ca.customer_id and ca.is_default_shipping = true
group by 1, 2, 3
