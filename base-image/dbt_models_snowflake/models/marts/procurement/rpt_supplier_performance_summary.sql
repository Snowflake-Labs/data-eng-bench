-- Supplier Performance Summary
-- Summarizes supplier performance

with supplier_performance_scores as (
    select * from {{ ref('stg_procurement__supplier_performance_scores') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_name,
    s.supplier_type,
    count(distinct sps.score_id) as score_periods,
    avg(sps.quality_score) as avg_quality_score,
    avg(sps.delivery_score) as avg_delivery_score,
    avg(sps.overall_score) as avg_overall_score,
    min(sps.period_date) as first_scored_period,
    max(sps.period_date) as last_scored_period
from supplier_performance_scores sps
left join suppliers s on sps.supplier_id = s.supplier_id
group by 1, 2
