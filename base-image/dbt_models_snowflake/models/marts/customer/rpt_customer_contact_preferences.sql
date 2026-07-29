-- Customer Contact Preferences Analysis
-- Analyzes customer contact methods and preferences

with customer_contacts as (
    select * from {{ ref('stg_customer__customer_contacts') }}
),

customer_preferences as (
    select * from {{ ref('stg_customer__customer_preferences') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    c.customer_id,
    c.customer_number,
    c.email as primary_email,
    count(distinct cc.contact_id) as total_contact_methods,
    count(distinct case when cc.is_primary then cc.contact_id end) as primary_contacts,
    count(distinct case when cc.is_verified then cc.contact_id end) as verified_contacts,
    count(distinct cc.contact_type) as contact_types_count,
    count(distinct cp.preference_id) as total_preferences,
    count(distinct cp.preference_category) as preference_categories
from customers c
left join customer_contacts cc on c.customer_id = cc.customer_id
left join customer_preferences cp on c.customer_id = cp.customer_id
group by 1, 2, 3
