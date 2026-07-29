-- Dim Customer Master
-- Comprehensive customer dimension with all attributes

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

customer_tiers as (
    select * from {{ ref('stg_customer__customer_tiers') }}
),

customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

default_shipping as (
    select
        customer_id,
        city as shipping_city,
        state_province as shipping_state,
        country_code as shipping_country,
        postal_code as shipping_postal_code
    from customer_addresses
    where is_default_shipping
    qualify row_number() over (partition by customer_id order by created_at desc) = 1
)

select
    c.customer_id,
    c.customer_number,
    c.first_name,
    c.last_name,
    c.email,
    c.customer_type,
    c.status,
    ct.tier_name,
    ct.tier_level,
    ct.discount_percentage as tier_discount_pct,
    ds.shipping_city,
    ds.shipping_state,
    ds.shipping_country,
    ds.shipping_postal_code,
    c.created_at as customer_since,
    c.updated_at as last_updated
from customers c
left join customer_tiers ct on c.current_tier_id = ct.tier_id
left join default_shipping ds on c.customer_id = ds.customer_id
