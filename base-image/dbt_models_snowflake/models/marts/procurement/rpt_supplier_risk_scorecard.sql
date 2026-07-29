with po_stats as (
    select
        supplier_id,
        DATEDIFF(day, ordered_at::date, expected_date) as lead_time_days
    from {{ ref('stg_procurement__purchase_orders') }}
    where status = 'DELIVERED'
)

select
    s.supplier_name,
    avg(p.lead_time_days) as avg_lead_time,
    stddev(p.lead_time_days) as lead_time_variability,
    count(*) as po_count,
    case
        when stddev(p.lead_time_days) > 5 then 'High Risk'
        when stddev(p.lead_time_days) > 2 then 'Medium Risk'
        else 'Low Risk'
    end as reliability_status
from {{ ref('stg_procurement__suppliers') }} s
join po_stats p on s.supplier_id = p.supplier_id
group by 1
