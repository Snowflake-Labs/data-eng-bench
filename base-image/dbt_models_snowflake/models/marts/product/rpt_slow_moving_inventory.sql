with sales as (
    select * from {{ ref('fct_product_sales_performance') }}
),
inventory as (
    select variant_id, sum(quantity_on_hand) as current_stock
    from {{ ref('stg_inventory__inventory_levels') }}
    group by 1
),
products as (
    select * from {{ ref('dim_products_enriched') }}
),
product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    p.product_name,
    p.category_name,
    coalesce(sum(i.current_stock), 0) as current_stock,
    COALESCE(s.total_units_sold, 0) as units_sold,
    case
        when s.total_units_sold is null or s.total_units_sold = 0 then 'Dead Stock'
        when sum(i.current_stock) > (s.total_units_sold * 2) then 'Slow Moving'
        else 'Healthy'
    end as stock_status
from products p
left join product_variants pv on p.product_id = pv.product_id
left join inventory i on pv.variant_id = i.variant_id
left join sales s on p.product_id = s.product_id
group by p.product_name, p.category_name, s.total_units_sold
