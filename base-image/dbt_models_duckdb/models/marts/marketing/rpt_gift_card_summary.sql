-- Gift Card Summary
-- Summarizes gift cards

with gift_cards as (
    select * from {{ ref('stg_marketing__gift_cards') }}
),

gift_card_transactions as (
    select * from {{ ref('stg_marketing__gift_card_transactions') }}
)

select
    gc.status,
    count(distinct gc.gift_card_id) as card_count,
    sum(gc.initial_value) as total_initial_value,
    sum(gc.current_balance) as total_current_balance,
    sum(gc.initial_value) - sum(gc.current_balance) as total_redeemed,
    count(distinct gct.transaction_id) as total_transactions
from gift_cards gc
left join gift_card_transactions gct on gc.gift_card_id = gct.gift_card_id
group by 1
