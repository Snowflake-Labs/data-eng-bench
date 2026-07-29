/*
================================================================================
rpt_top_customers - Top Customers Report (RFM Analysis)
================================================================================
Identification of high-value customers based on lifetime value (LTV),
frequency, and recency (RFM analysis inputs) to drive loyalty programs.

BUSINESS CONTEXT:
- Powers the "VIP Customer Dashboard" in Tableau
- Used by Customer Success team for outreach prioritization
- Feeds loyalty tier assignments in Braze/Iterable
- CFO reviews top 50 quarterly

IMPORTANT: This model contains PII (customer names, emails)!
- Do not share raw output externally
- Apply column masking in BI tools
- Subject to GDPR Article 17 requests

SLA: Must complete by 6am UTC for Loyalty team morning sync.

Code Review Comments (preserved for context):
- Customer Success (2023-08-01): "Can we add phone numbers?"
- Legal (2023-08-01): "NO. Minimal PII principle. Use CRM for contact."
- Marcus (2024-02-15): "The LIMIT 500 seems arbitrary"
- Sarah (2024-02-15): "CS team only reviews top 500. Full list available in Looker."
- Finance (2024-06-01): "LTV calculation should exclude shipping"
- Sarah (2024-06-01): "Agreed, but need to align with Marketing's definition first"
- Marketing (2024-06-15): "Let's discuss in Q3 planning" (still not resolved)
================================================================================
*/

{{
    config(
        materialized='table',
        tags=['marts', 'sales', 'customers', 'rfm', 'pii', 'sla_critical'],
        meta={
            'owner': 'customer-success@company.com',
            'sla': '6:00am UTC',
            'estimated_runtime_minutes': 8,
            'snowflake_warehouse': 'TRANSFORM_M',
            'contains_pii': true,
            'pii_columns': ['first_name', 'last_name', 'email', 'full_name'],
            'tableau_workbooks': ['VIP Customer Dashboard'],
            'downstream_systems': ['Braze', 'Iterable', 'Zendesk'],
            'business_owner': 'VP Customer Success',
            'executive_visibility': true
        }
    )
}}

with orders as (
    select * from {{ ref('fct_orders_master') }}
),

customers as (
    select * from {{ ref('dim_customers_enriched') }}
),

-- Aggregate customer purchase history
customer_stats as (
    select
        o.customer_id,
        count(o.order_id) as lifetime_orders,
        sum(o.total_amount) as lifetime_value,
        avg(o.total_amount) as avg_order_value,
        min(o.ordered_at) as first_order_date,
        max(o.ordered_at) as last_order_date,
        -- Recent activity
        sum(case when o.ordered_at >= current_date - interval '365 days' then o.total_amount else 0 end) as last_12m_value,
        count(case when o.ordered_at >= current_date - interval '365 days' then 1 end) as last_12m_orders
    from orders o
    where o.status not in ('CANCELLED', 'RETURNED')
    group by 1
),

-- Rank and segment customers
ranked_customers as (
    select
        cs.*,
        -- Percentile ranking for segmentation
        percent_rank() over (order by cs.lifetime_value) as ltv_percentile,
        date_diff('day', cs.last_order_date, current_date) as days_since_last_order,
        date_diff('day', cs.first_order_date, current_date) as customer_tenure_days
    from customer_stats cs
)

select 
    c.customer_id,
    c.first_name,
    c.last_name,
    concat(c.first_name, ' ', c.last_name) as full_name,
    c.email,
    c.country_code,
    c.city,
    -- Lifetime Metrics
    rc.lifetime_orders,
    round(rc.lifetime_value, 2) as lifetime_value,
    round(rc.avg_order_value, 2) as avg_order_value,
    -- Recency & Tenure
    rc.first_order_date,
    rc.last_order_date,
    rc.days_since_last_order,
    rc.customer_tenure_days,
    -- Recent Performance
    round(rc.last_12m_value, 2) as last_12m_value,
    rc.last_12m_orders,
    -- Status Indicators
    case 
        when rc.last_12m_orders > 0 then 'Active'
        else 'Lapsed'
    end as status,
    -- VIP Segmentation
    case
        when rc.ltv_percentile >= 0.99 then 'Diamond VIP'
        when rc.ltv_percentile >= 0.95 then 'Platinum'
        when rc.ltv_percentile >= 0.80 then 'Gold'
        when rc.ltv_percentile >= 0.50 then 'Silver'
        else 'Standard'
    end as loyalty_tier
from ranked_customers rc
join customers c on rc.customer_id = c.customer_id
order by rc.lifetime_value desc
limit 500