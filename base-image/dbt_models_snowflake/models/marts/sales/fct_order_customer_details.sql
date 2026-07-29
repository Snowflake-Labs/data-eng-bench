-- Order with Customer Details
-- Joins orders with customer information

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    o.order_id,
    o.order_number,
    c.customer_id,
    c.first_name,
    c.last_name,
    c.email,
    c.customer_type
from orders o
left join customers c on o.customer_id = c.customer_id
