-- Order Fraud Score Analysis
-- Analyzes fraud scores on orders

with order_fraud_scores as (
    select * from {{ ref('stg_orders__order_fraud_scores') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    ofs.risk_level,
    count(distinct ofs.order_id) as order_count,
    avg(ofs.score) as avg_fraud_score,
    min(ofs.score) as min_fraud_score,
    max(ofs.score) as max_fraud_score,
    sum(o.grand_total) as total_order_value,
    avg(o.grand_total) as avg_order_value
from order_fraud_scores ofs
left join orders o on ofs.order_id = o.order_id
group by 1
