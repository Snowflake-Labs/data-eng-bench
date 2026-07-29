{{
    config(
        materialized='table',
        tags=['dimension', 'product']
    )
}}

with product_categories as (
    select
        category_id,
        category_name,
        parent_category_id,
        category_level,
        is_active,
        created_at,
        updated_at
    from {{ ref('stg_product__product_categories') }}
),

category_hierarchy as (
    select
        pc.category_id,
        pc.category_name,
        pc.parent_category_id,
        parent.category_name as parent_category_name,
        pc.category_level,
        pc.is_active,
        pc.created_at,
        pc.updated_at
    from product_categories pc
    left join product_categories parent on pc.parent_category_id = parent.category_id
),

category_products as (
    select
        category_id,
        count(distinct product_id) as product_count
    from {{ ref('stg_product__product_category_mapping') }}
    group by category_id
),

final as (
    select
        ch.category_id,
        ch.category_name,
        ch.parent_category_id,
        ch.parent_category_name,
        ch.category_level,
        coalesce(cp.product_count, 0) as product_count,
        ch.is_active,
        ch.created_at as category_created_at,
        current_timestamp as dbt_updated_at
    from category_hierarchy ch
    left join category_products cp on ch.category_id = cp.category_id
)

select * from final
