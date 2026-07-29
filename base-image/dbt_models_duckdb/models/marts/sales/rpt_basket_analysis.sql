/*
================================================================================
rpt_basket_analysis - Basket Composition Analysis Report
================================================================================
Analyzes order basket composition for merchandising insights.

Used by: Merchandising team, Category Managers
Refresh: Daily
Output: ~500K rows (one per order)

BUSINESS CONTEXT:
This report powers the "Basket Insights" dashboard in Looker.
Category managers use it to understand cross-category purchasing patterns.

Code Review Comments (preserved for context):
- Merchandising (2023-06-01): "Can we add product affinity scores?"
- Sarah (2023-06-01): "That's a different model - see rpt_cross_sell_analysis"
- Marcus (2024-01-15): "Performance degraded after product catalog growth"
- Sarah (2024-01-15): "Added clustering, should help"
- Analytics (2024-09-01): "highest_priced_item seems wrong sometimes"
- Sarah (2024-09-01): "Known issue with bundle pricing - tracking in DATA-3102"
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['marts', 'sales', 'basket', 'merchandising'],
        cluster_by=['order_id'],
        meta={
            'owner': 'merchandising-analytics@company.com',
            'sla': '7:00am UTC',
            'estimated_runtime_minutes': 5,
            'snowflake_warehouse': 'TRANSFORM_M',
            'looker_explores': ['basket_analysis'],
            'business_owner': 'Category Management Team',
            'known_issues': ['Bundle pricing affects highest_priced_item - DATA-3102']
        }
    )
}}

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
)

select
    o.order_id,
    count(distinct ol.order_line_id) as line_items,
    count(distinct p.primary_category_id) as unique_categories,
    count(distinct p.product_id) as unique_products,
    sum(ol.quantity_ordered) as total_units,
    sum(ol.line_total - ol.discount_amount) as basket_value,
    max(ol.unit_price) as highest_priced_item,
    min(ol.unit_price) as lowest_priced_item,
    avg(ol.unit_price) as avg_item_price
from orders o
left join order_lines ol on o.order_id = ol.order_id
left join product_variants pv on ol.variant_id = pv.variant_id
left join products p on pv.product_id = p.product_id
group by 1