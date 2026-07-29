-- Profit Center Summary
-- Summarizes profit centers

with profit_centers as (
    select * from {{ ref('stg_finance__profit_centers') }}
)

select
    profit_center_id,
    profit_center_code,
    profit_center_name,
    created_at
from profit_centers
