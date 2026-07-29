-- Sales Return Detail
-- Detailed return analysis

with returns as (
    select * from {{ ref('stg_orders__returns') }}
),

return_lines as (
    select * from {{ ref('stg_orders__return_lines') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    r.return_id,
    r.return_number,
    o.order_id,
    o.order_number,
    c.customer_id,
    c.first_name || ' ' || c.last_name as customer_name,
    pv.sku,
    p.product_name,
    rl.refund_amount
from returns r
left join return_lines rl on r.return_id = rl.return_id
left join order_lines ol on rl.order_line_id = ol.order_line_id
left join orders o on r.order_id = o.order_id
left join customers c on o.customer_id = c.customer_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id