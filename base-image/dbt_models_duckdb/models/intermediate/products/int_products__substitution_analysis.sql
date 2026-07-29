{{
    config(
        materialized='view',
        tags=['intermediate', 'products']
    )
}}

with product_pairs as (
    select
        s1.order_id,
        s1.product_id as product_a,
        s2.product_id as product_b
    from {{ ref('fct_sales') }} s1
    inner join {{ ref('fct_sales') }} s2
        on s1.order_id = s2.order_id
        and s1.product_id < s2.product_id
    where s1.is_cancelled = false
        and s2.is_cancelled = false
),

pair_frequency as (
    select
        product_a,
        product_b,
        count(distinct order_id) as co_purchase_count
    from product_pairs
    group by product_a, product_b
    having count(distinct order_id) >= 5
),

product_totals as (
    select
        product_id,
        count(distinct order_id) as product_order_count
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by product_id
),

substitution_scores as (
    select
        p.product_a,
        p.product_b,
        p.co_purchase_count,
        t1.product_order_count as product_a_orders,
        t2.product_order_count as product_b_orders,
        round(100.0 * p.co_purchase_count / least(t1.product_order_count, t2.product_order_count), 2) as affinity_score
    from pair_frequency p
    inner join product_totals t1 on p.product_a = t1.product_id
    inner join product_totals t2 on p.product_b = t2.product_id
)

select * from substitution_scores
where affinity_score >= 10
order by affinity_score desc
