-- Customer Preference Trends
-- Tracks preference changes over time

with customer_preferences as (
    select * from {{ ref('stg_customer__customer_preferences') }}
)

select
    date_trunc('month', updated_at) as update_month,
    preference_category,
    preference_key,
    count(distinct customer_id) as customers_updating,
    count(distinct preference_value) as unique_values
from customer_preferences
where updated_at is not null
group by 1, 2, 3
order by 1, 2
