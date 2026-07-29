with src_stg_orders__orders as (
    select * from {{ ref('stg_orders__orders') }}
),
src_dim_products_enriched as (
    select * from {{ ref('dim_products_enriched') }}
),
src_dim_customers_enriched as (
    select * from {{ ref('dim_customers_enriched') }}
),
src_stg_product__product_categories as (
    select * from {{ ref('stg_product__product_categories') }}
),
src_stg_orders__order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),
customer_categories as (
    select distinct 
        o.customer_id, 
        p.category_id,
        p.category_name
    from src_stg_orders__orders o
    join src_stg_orders__order_lines ol on o.order_id = ol.order_id
    join src_dim_products_enriched p on ol.product_id = p.product_id
),
categories as (
    select distinct category_id, category_name from src_stg_product__product_categories
)

-- Example: Find customers who bought 'Electronics' but never 'Accessories'
-- This logic assumes dynamic cross join or specific targeting, putting a generic framework here
select 
    c.customer_id,
    c.first_name,
    c.last_name,
    cat.category_name as missing_category
from src_dim_customers_enriched c
cross join categories cat
left join customer_categories cc 
    on c.customer_id = cc.customer_id 
    and cat.category_id = cc.category_id
where cc.category_id is null