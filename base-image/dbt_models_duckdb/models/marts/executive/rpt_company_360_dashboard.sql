with src_fct_orders_master as (
    select * from {{ ref('fct_orders_master') }}
),
src_stg_inventory__inventory_levels as (
    select * from {{ ref('stg_inventory__inventory_levels') }}
),
src_fct_employee_roster as (
    select * from {{ ref('fct_employee_roster') }}
),

-- A union or join of scalar values for a dashboard
sales as (
    select sum(total_amount) as total_revenue from src_fct_orders_master
),
inventory as (
    select sum(quantity_on_hand * unit_cost) as inventory_value 
    from src_stg_inventory__inventory_levels 
),
employees as (
    select count(*) as headcount from src_fct_employee_roster
)

select 
    s.total_revenue,
    i.inventory_value,
    e.headcount,
    current_date as report_date
from sales s, inventory i, employees e