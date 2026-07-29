-- Currency Exchange Rate Trends
-- Tracks exchange rate changes

with currency_exchange_rates as (
    select * from {{ ref('stg_finance__currency_exchange_rates') }}
)

select
    from_currency,
    to_currency,
    effective_date,
    exchange_rate,
    lag(exchange_rate) over (partition by from_currency, to_currency order by effective_date) as prev_rate,
    exchange_rate - lag(exchange_rate) over (partition by from_currency, to_currency order by effective_date) as rate_change
from currency_exchange_rates
order by from_currency, to_currency, effective_date
