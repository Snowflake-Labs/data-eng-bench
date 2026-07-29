-- ABC Supplier Classification
-- Classifies suppliers into A (top 20% spend), B (next 30%), C (remaining 50%)

with supplier_spend as (
    select
        supplier_id,
        supplier_name,
        sum(total_amount) as total_spend,
        count(distinct po_number) as po_count,
        count(distinct product_id) as product_count,
        min(po_date) as first_po_date,
        max(po_date) as last_po_date
    from {{ ref('fct_purchase_orders') }}
    where supplier_id is not null
    group by supplier_id, supplier_name
),

ranked_suppliers as (
    select
        supplier_id,
        supplier_name,
        total_spend,
        po_count,
        product_count,
        first_po_date,
        last_po_date,
        sum(total_spend) over () as grand_total,
        sum(total_spend) over (order by total_spend desc) as cumulative_spend,
        row_number() over (order by total_spend desc) as spend_rank
    from supplier_spend
),

classified_suppliers as (
    select
        supplier_id,
        supplier_name,
        total_spend,
        po_count,
        product_count,
        first_po_date,
        last_po_date,
        spend_rank,
        round(100.0 * total_spend / grand_total, 2) as pct_of_total_spend,
        round(100.0 * cumulative_spend / grand_total, 2) as cumulative_pct,
        case
            when cumulative_spend / grand_total <= 0.80 then 'A - Top 80% Spend'
            when cumulative_spend / grand_total <= 0.95 then 'B - Next 15% Spend'
            else 'C - Bottom 5% Spend'
        end as abc_class
    from ranked_suppliers
)

select
    abc_class,
    count(*) as supplier_count,
    sum(total_spend) as total_spend,
    round(avg(total_spend), 2) as avg_spend_per_supplier,
    sum(po_count) as total_pos,
    round(avg(po_count), 2) as avg_pos_per_supplier,
    sum(product_count) as total_products_sourced
from classified_suppliers
group by abc_class
order by
    case abc_class
        when 'A - Top 80% Spend' then 1
        when 'B - Next 15% Spend' then 2
        when 'C - Bottom 5% Spend' then 3
    end
