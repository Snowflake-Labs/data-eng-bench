-- Supplier Orders Fact Table
-- Comprehensive supplier performance analytics with spend analysis,
-- lead time tracking, reliability scoring, and strategic sourcing insights

with orders as (
    select * from {{ ref('stg_procurement__purchase_orders') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),

-- Calculate order-level metrics
order_metrics as (
    select
        o.po_id,
        o.po_number,
        o.supplier_id,
        o.warehouse_id,
        o.status,
        o.total_amount,
        o.currency_code,
        o.ordered_at,
        o.expected_date,
        o.created_by,
        -- Lead time calculation
        DATEDIFF(day, o.ordered_at::date, o.expected_date) as expected_lead_time_days,
        -- Time-based dimensions
        DATE_TRUNC('month', o.ordered_at) as order_month,
        DATE_TRUNC(quarter, o.ordered_at) as order_quarter,
        extract(year from o.ordered_at) as order_year,
        extract(month from o.ordered_at) as order_month_num,
        -- Order status flags
        case when o.status = 'RECEIVED' then true else false end as is_received,
        case when o.status = 'CANCELLED' then true else false end as is_cancelled,
        case when o.status = 'PENDING' then true else false end as is_pending,
        case when o.status in ('SHIPPED', 'IN_TRANSIT') then true else false end as is_in_transit
    from orders o
),

-- Supplier-level aggregations
supplier_aggregates as (
    select
        om.supplier_id,
        count(om.po_id) as total_po_count,
        count(case when om.is_received then 1 end) as received_po_count,
        count(case when om.is_cancelled then 1 end) as cancelled_po_count,
        count(case when om.is_pending then 1 end) as pending_po_count,
        count(case when om.is_in_transit then 1 end) as in_transit_po_count,
        sum(om.total_amount) as total_spend,
        avg(om.total_amount) as avg_order_value,
        min(om.total_amount) as min_order_value,
        max(om.total_amount) as max_order_value,
        stddev(om.total_amount) as order_value_std_dev,
        -- Lead time metrics
        avg(om.expected_lead_time_days) as avg_expected_lead_time,
        min(om.expected_lead_time_days) as min_lead_time,
        max(om.expected_lead_time_days) as max_lead_time,
        -- Date range
        min(om.ordered_at) as first_order_date,
        max(om.ordered_at) as last_order_date,
        count(distinct om.order_month) as active_months,
        count(distinct om.warehouse_id) as warehouses_served
    from order_metrics om
    group by om.supplier_id
),

-- Calculate year-over-year and recent trends
recent_orders as (
    select
        om.supplier_id,
        count(case when om.ordered_at >= DATEADD(day, -30, current_date) then 1 end) as orders_last_30_days,
        count(case when om.ordered_at >= DATEADD(day, -90, current_date) then 1 end) as orders_last_90_days,
        sum(case when om.ordered_at >= DATEADD(day, -30, current_date) then om.total_amount else 0 end) as spend_last_30_days,
        sum(case when om.ordered_at >= DATEADD(day, -90, current_date) then om.total_amount else 0 end) as spend_last_90_days,
        sum(case when om.order_year = extract(year from current_date) then om.total_amount else 0 end) as ytd_spend,
        sum(case when om.order_year = extract(year from current_date) - 1 then om.total_amount else 0 end) as prior_year_spend
    from order_metrics om
    group by om.supplier_id
),

-- Portfolio-level totals for share calculations
portfolio_totals as (
    select
        sum(total_amount) as total_portfolio_spend,
        count(distinct supplier_id) as total_suppliers
    from order_metrics
),

-- Final supplier performance report
final as (
    select
        -- Supplier details
        s.supplier_id,
        s.supplier_code,
        s.supplier_name,
        s.supplier_type,
        s.payment_terms,
        s.currency_code as supplier_currency,
        s.lead_time_days as contracted_lead_time,
        s.min_order_value as contracted_min_order_value,
        s.rating as supplier_rating,
        s.status as supplier_status,
        -- Order volume metrics
        sa.total_po_count,
        sa.received_po_count,
        sa.cancelled_po_count,
        sa.pending_po_count,
        sa.in_transit_po_count,
        -- Cancellation rate
        round(100.0 * sa.cancelled_po_count / nullif(sa.total_po_count, 0), 1) as cancellation_rate_pct,
        -- Financial metrics
        round(sa.total_spend, 2) as total_spend,
        round(sa.avg_order_value, 2) as avg_order_value,
        round(sa.min_order_value, 2) as min_order_value,
        round(sa.max_order_value, 2) as max_order_value,
        -- Lead time performance
        round(sa.avg_expected_lead_time, 1) as avg_expected_lead_time_days,
        sa.min_lead_time as min_lead_time_days,
        sa.max_lead_time as max_lead_time_days,
        round(sa.avg_expected_lead_time - s.lead_time_days, 1) as lead_time_variance_days,
        case
            when s.lead_time_days is null then 'No Contract'
            when sa.avg_expected_lead_time <= s.lead_time_days then 'Within Contract'
            when sa.avg_expected_lead_time <= s.lead_time_days * 1.1 then 'Slightly Over'
            else 'Exceeds Contract'
        end as lead_time_compliance,
        -- Relationship longevity
        sa.first_order_date,
        sa.last_order_date,
        DATEDIFF(day, sa.first_order_date, current_date) as days_as_supplier,
        DATEDIFF(day, sa.last_order_date, current_date) as days_since_last_order,
        sa.active_months,
        sa.warehouses_served,
        -- Recent activity
        ro.orders_last_30_days,
        ro.orders_last_90_days,
        round(ro.spend_last_30_days, 2) as spend_last_30_days,
        round(ro.spend_last_90_days, 2) as spend_last_90_days,
        round(ro.ytd_spend, 2) as ytd_spend,
        round(ro.prior_year_spend, 2) as prior_year_spend,
        -- YoY growth
        case
            when ro.prior_year_spend > 0
            then round(100.0 * (ro.ytd_spend - ro.prior_year_spend) / ro.prior_year_spend, 1)
            else null
        end as yoy_spend_growth_pct,
        -- Share of wallet
        round(100.0 * sa.total_spend / nullif(pt.total_portfolio_spend, 0), 2) as pct_of_total_spend,
        -- Supplier tier classification
        case
            when sa.total_spend >= pt.total_portfolio_spend * 0.1 then 'Strategic'
            when sa.total_spend >= pt.total_portfolio_spend * 0.03 then 'Preferred'
            when sa.total_spend >= pt.total_portfolio_spend * 0.01 then 'Approved'
            else 'Transactional'
        end as supplier_tier,
        -- Activity status
        case
            when DATEDIFF(day, sa.last_order_date, current_date) <= 30 then 'Active'
            when DATEDIFF(day, sa.last_order_date, current_date) <= 90 then 'Recent'
            when DATEDIFF(day, sa.last_order_date, current_date) <= 180 then 'Dormant'
            else 'Inactive'
        end as activity_status,
        -- Order frequency
        case
            when sa.active_months > 0
            then round(sa.total_po_count::float / sa.active_months, 1)
            else null
        end as avg_orders_per_month
    from suppliers s
    left join supplier_aggregates sa on s.supplier_id = sa.supplier_id
    left join recent_orders ro on s.supplier_id = ro.supplier_id
    cross join portfolio_totals pt
    where s.status = 'ACTIVE'
)

select * from final
order by total_spend desc nulls last
