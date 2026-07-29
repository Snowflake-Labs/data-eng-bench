-- Customer Preference Categories
-- Aggregates customer preferences by category

with customer_preferences as (
    select * from {{ ref('stg_customer__customer_preferences') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    cp.preference_category,
    cp.preference_key,
    count(distinct cp.customer_id) as customers_with_preference,
    count(distinct cp.preference_value) as unique_values,
    min(cp.created_at) as first_set_at,
    max(cp.updated_at) as last_updated_at
from customer_preferences cp
left join customers c on cp.customer_id = c.customer_id
group by 1, 2
