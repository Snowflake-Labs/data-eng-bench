-- Customer Note Types Distribution
-- Analyzes distribution of note types

with customer_notes as (
    select * from {{ ref('stg_customer__customer_notes') }}
)

select
    note_type,
    count(distinct customer_id) as customers_with_notes,
    count(distinct note_id) as total_notes,
    count(distinct created_by) as unique_authors,
    avg(length(note_content)) as avg_note_length,
    min(created_at) as first_note,
    max(created_at) as last_note
from customer_notes
group by 1
