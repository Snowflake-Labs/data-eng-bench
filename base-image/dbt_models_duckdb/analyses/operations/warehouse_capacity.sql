-- Warehouse Capacity Utilization Analysis

with warehouse_inventory as (
    select
        warehouse_name,
        sum(quantity_available) as total_units,
        count(distinct product_id) as unique_products
    from {{ ref('stg_inventory__inventory_levels') }}
    group by warehouse_name
),

warehouse_info as (
    select
        warehouse_name,
        total_capacity_sqft,
        usable_capacity_sqft,
        warehouse_type
    from {{ ref('stg_inventory__warehouses') }}
),

utilization_calc as (
    select
        w.warehouse_name,
        w.warehouse_type,
        w.total_capacity_sqft,
        w.usable_capacity_sqft,
        i.total_units,
        i.unique_products,
        -- Assume 10 sqft per pallet, 100 units per pallet
        round((i.total_units / 100.0) * 10, 2) as estimated_space_used_sqft,
        round(100.0 * ((i.total_units / 100.0) * 10) / nullif(w.usable_capacity_sqft, 0), 2) as utilization_pct,
        round(w.usable_capacity_sqft - (i.total_units / 100.0) * 10, 2) as available_space_sqft
    from warehouse_info w
    left join warehouse_inventory i on w.warehouse_name = i.warehouse_name
),

final as (
    select
        warehouse_name,
        warehouse_type,
        total_capacity_sqft,
        usable_capacity_sqft,
        total_units,
        unique_products,
        estimated_space_used_sqft,
        utilization_pct,
        available_space_sqft,
        case
            when utilization_pct >= 95 then 'Critical - At Capacity'
            when utilization_pct >= 85 then 'High - Near Capacity'
            when utilization_pct >= 70 then 'Moderate Utilization'
            when utilization_pct >= 50 then 'Good Utilization'
            else 'Low Utilization'
        end as capacity_status
    from utilization_calc
)

select * from final
order by utilization_pct desc
