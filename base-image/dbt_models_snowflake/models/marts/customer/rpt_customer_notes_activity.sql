-- Customer Notes Activity
-- Summarizes note-taking activity for customers

with customer_notes as (
    select * from {{ ref('stg_customer__customer_notes') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    cn.customer_id,
    c.customer_number,
    c.first_name,
    c.last_name,
    count(distinct cn.note_id) as total_notes,
    count(distinct cn.note_type) as note_types_count,
    count(distinct cn.created_by) as unique_note_authors,
    min(cn.created_at) as first_note_at,
    max(cn.created_at) as last_note_at
from customer_notes cn
left join customers c on cn.customer_id = c.customer_id
group by 1, 2, 3, 4
