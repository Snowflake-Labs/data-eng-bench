with monthly_sales as (
    select 
        p.product_id,
        p.product_name,
        p.primary_category_id,
        date_trunc('month', o.ordered_at) as sales_month,
        sum(ol.quantity_ordered) as units_sold
    from {{ ref('stg_orders__order_lines') }} ol
    join {{ ref('stg_orders__orders') }} o on ol.order_id = o.order_id
    join {{ ref('stg_product__products') }} p on ol.product_id = p.product_id
    group by 1,2,3,4
)

select 
    m1.primary_category_id,
    m1.product_name as product_a,
    m2.product_name as product_b,
    corr(m1.units_sold, m2.units_sold) as sales_correlation
from monthly_sales m1
join monthly_sales m2 on m1.primary_category_id = m2.primary_category_id 
    and m1.sales_month = m2.sales_month 
    and m1.product_id != m2.product_id
group by 1,2,3
having corr(m1.units_sold, m2.units_sold) < -0.5