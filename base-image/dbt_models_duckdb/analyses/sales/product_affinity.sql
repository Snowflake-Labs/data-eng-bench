-- Product Affinity Analysis
-- Products frequently purchased together

with order_pairs as (
    select
        o1.order_id,
        o1.product_id as product_a,
        o1.product_name as product_a_name,
        o2.product_id as product_b,
        o2.product_name as product_b_name
    from {{ ref('fct_sales') }} o1
    inner join {{ ref('fct_sales') }} o2
        on o1.order_id = o2.order_id
        and o1.product_id < o2.product_id
    where o1.is_cancelled = false
        and o2.is_cancelled = false
),

pair_frequency as (
    select
        product_a,
        product_a_name,
        product_b,
        product_b_name,
        count(distinct order_id) as co_purchase_count
    from order_pairs
    group by product_a, product_a_name, product_b, product_b_name
    having count(distinct order_id) >= 10
),

product_totals as (
    select
        product_id,
        count(distinct order_id) as total_orders
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by product_id
),

affinity_scores as (
    select
        p.product_a,
        p.product_a_name,
        p.product_b,
        p.product_b_name,
        p.co_purchase_count,
        t1.total_orders as product_a_orders,
        t2.total_orders as product_b_orders,
        round(100.0 * p.co_purchase_count / least(t1.total_orders, t2.total_orders), 2) as affinity_score,
        round(100.0 * p.co_purchase_count / t1.total_orders, 2) as lift_from_a,
        round(100.0 * p.co_purchase_count / t2.total_orders, 2) as lift_from_b
    from pair_frequency p
    inner join product_totals t1 on p.product_a = t1.product_id
    inner join product_totals t2 on p.product_b = t2.product_id
)

select * from affinity_scores
where affinity_score >= 20
order by affinity_score desc
limit 100
