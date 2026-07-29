-- Gift Card Transaction Analysis
-- Analyzes gift card transactions

with gift_card_transactions as (
    select * from {{ ref('stg_marketing__gift_card_transactions') }}
),

gift_cards as (
    select * from {{ ref('stg_marketing__gift_cards') }}
)

select
    gct.transaction_type,
    count(distinct gct.transaction_id) as transaction_count,
    count(distinct gct.gift_card_id) as cards_affected,
    sum(gct.amount) as total_amount,
    avg(gct.amount) as avg_amount,
    count(distinct gct.order_id) as orders_with_gift_card
from gift_card_transactions gct
left join gift_cards gc on gct.gift_card_id = gc.gift_card_id
group by 1
