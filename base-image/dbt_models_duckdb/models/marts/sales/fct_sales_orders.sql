with header as (
    select * from {{ ref('stg_raw_sap__vbak') }}
),
items as (
    select * from {{ ref('stg_raw_sap__vbap') }}
)

select 
    h.order_id,
    h.order_number,
    h.ordered_at,
    h.customer_id,
    h.channel_id,
    i.order_line_id,
    i.product_id,
    i.quantity_ordered,
    i.unit_price,
    h.currency_code
from header h
join items i on h.order_id = i.order_id