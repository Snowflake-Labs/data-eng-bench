{{
    config(
        materialized='view',
        tags=['staging', 'marketing']
    )
}}

select
    event_id,
    customer_id,
    campaign_id,
    event_type,
    event_at,
    created_at
from {{ source('main', 'stg_marketing__email_events') }}
