-- Accounts Payable Aging Report (Projected)
-- Projects future cash outflows based on Open Purchase Orders.
-- Note: Uses PO data as proxy for AP liabilities due to lack of open item details in BSIK.

with open_orders as (
    -- Identifying liabilities from procurement system
    select * from {{ ref('stg_procurement__purchase_orders') }}
    where status not in ('CANCELLED', 'REJECTED')
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),

-- Calculate aging buckets based on expected payment date
aging_calculation as (
    select
        po.po_id,
        po.po_number,
        po.supplier_id,
        -- Defaulting due date to expected delivery + 30 days (standard term assumption)
        -- since specific invoice terms aren't in the staging model
        DATEADD(day, 30, po.expected_date)::date as estimated_due_date,
        po.total_amount as amount_due,
        po.status,

        -- Current date for aging is assumed to be 'today'
        DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) as days_until_due,

        -- Categorize liabilities
        case
            -- Overdue
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) < 0 then 'Overdue'
            -- Future liabilities
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) <= 30 then 'Due 0-30 Days'
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) <= 60 then 'Due 31-60 Days'
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) <= 90 then 'Due 61-90 Days'
            else 'Due 90+ Days'
        end as aging_bucket,

        -- Sorting helper
        case
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) < 0 then 1
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) <= 30 then 2
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) <= 60 then 3
            when DATEDIFF(day, current_date, DATEADD(day, 30, po.expected_date)::date) <= 90 then 4
            else 5
        end as bucket_sort_order
    from open_orders po
),

-- Aggregating liabilities by supplier and bucket
supplier_aging_summary as (
    select
        ac.supplier_id,
        count(ac.po_id) as open_invoice_count,
        sum(ac.amount_due) as total_liability,

        -- Pivot buckets
        sum(case when ac.aging_bucket = 'Overdue' then ac.amount_due else 0 end) as amount_overdue,
        sum(case when ac.aging_bucket = 'Due 0-30 Days' then ac.amount_due else 0 end) as amount_due_0_30,
        sum(case when ac.aging_bucket = 'Due 31-60 Days' then ac.amount_due else 0 end) as amount_due_31_60,
        sum(case when ac.aging_bucket = 'Due 61-90 Days' then ac.amount_due else 0 end) as amount_due_61_90,
        sum(case when ac.aging_bucket = 'Due 90+ Days' then ac.amount_due else 0 end) as amount_due_90_plus,

        min(ac.estimated_due_date) as next_payment_date
    from aging_calculation ac
    group by ac.supplier_id
),

final as (
    select
        s.supplier_id,
        s.supplier_name,
        s.supplier_code,
        s.payment_terms,
        s.currency_code,
        coalesce(sas.open_invoice_count, 0) as open_invoice_count,
        coalesce(sas.total_liability, 0) as total_liability,
        coalesce(sas.amount_overdue, 0) as amount_overdue,
        coalesce(sas.amount_due_0_30, 0) as amount_due_0_30,
        coalesce(sas.amount_due_31_60, 0) as amount_due_31_60,
        coalesce(sas.amount_due_61_90, 0) as amount_due_61_90,
        coalesce(sas.amount_due_90_plus, 0) as amount_due_90_plus,
        sas.next_payment_date,

        -- Portfolio share
        round(100.0 * sas.total_liability / nullif(sum(sas.total_liability) over (), 0), 2) as pct_of_total_payables
    from suppliers s
    left join supplier_aging_summary sas on s.supplier_id = sas.supplier_id
    where sas.total_liability > 0 -- Only show suppliers with balance
)

select * from final
order by total_liability desc
