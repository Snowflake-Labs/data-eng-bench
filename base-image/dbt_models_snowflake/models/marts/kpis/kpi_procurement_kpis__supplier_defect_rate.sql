{{
    config(
        materialized='view',
        tags=['kpi', 'procurement_kpis']
    )
}}

with suppliers as (
    select
        supplier_id,
        supplier_name,
        rating
    from {{ ref('stg_procurement__suppliers') }}
),

performance_scores as (
    select
        supplier_id,
        quality_score
    from {{ ref('stg_procurement__supplier_performance_scores') }}
    where quality_score is not null
)

select
    'Supplier Defect Rate' as kpi_name,
    current_date as period,
    round(100.0 - avg(ps.quality_score), 2) as avg_defect_rate_pct,
    round(avg(ps.quality_score), 2) as avg_quality_score,
    count(distinct s.supplier_id) as supplier_count,
    current_timestamp as dbt_updated_at
from suppliers s
left join performance_scores ps on s.supplier_id = ps.supplier_id
where ps.quality_score is not null
