-- Tax Rate Summary
-- Summarizes tax rates

with tax_rates as (
    select * from {{ ref('stg_finance__tax_rates') }}
)

select
    tax_type,
    country_code,
    state_code,
    count(distinct tax_rate_id) as rate_count,
    avg(rate) as avg_rate,
    min(rate) as min_rate,
    max(rate) as max_rate,
    count(distinct tax_code) as unique_tax_codes
from tax_rates
group by 1, 2, 3
