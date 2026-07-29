-- Return Condition Analysis
-- Analyzes condition of returned items

with return_lines as (
    select * from {{ ref('stg_orders__return_lines') }}
),

returns as (
    select * from {{ ref('stg_orders__returns') }}
)

select
    rl.condition,
    count(distinct rl.return_id) as return_count,
    sum(rl.quantity_returned) as total_units_returned,
    count(distinct r.customer_id) as unique_customers
from return_lines rl
left join returns r on rl.return_id = r.return_id
group by 1
