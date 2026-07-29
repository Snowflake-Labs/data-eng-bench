{{
    config(
        materialized='view',
        tags=['staging', 'marketing']
    )
}}

select
    campaign_id,
    campaign_name,
    channel,
    start_date,
    end_date,
    budget,
    status,
    created_at
from {{ source('main', 'stg_marketing__campaigns') }}
