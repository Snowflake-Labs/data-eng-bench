{{
    config(
        materialized='table',
        tags=['mart', 'sales', 'returns']
    )
}}

with return_lines_agg as (
    select
        rl.return_id,
        count(*) as return_line_count,
        sum(rl.REFUND_AMOUNT) as total_refund_amount
    from {{ ref('stg_orders__return_lines') }} rl
    group by rl.return_id
),

returns_base as (
    select
        r.return_id,
        r.return_number,
        r.order_id,
        r.customer_id,
        r.return_type,
        r.refund_method,
        r.status,
        r.REFUND_AMOUNT as total_return_amount,
        coalesce(rla.total_refund_amount, 0) as total_refund_amount_lines,
        coalesce(rla.return_line_count, 0) as return_line_count,
        r.REQUESTED_AT as requested_at,
        r.RECEIVED_AT as received_at,
        r.PROCESSED_AT as processed_at
    from {{ ref('stg_orders__returns') }} r
    left join return_lines_agg rla on r.return_id = rla.return_id
    where r.status NOT IN ('REJECTED', 'CANCELLED')
),

with_timing as (
    select
        *,
        date_diff('day', requested_at, received_at) as days_to_receive,
        date_diff('day', received_at, processed_at) as days_to_process,
        date_diff('day', requested_at, processed_at) as total_processing_days,
        total_refund_amount_lines / total_return_amount as refund_completion_rate,
        1.0 / total_processing_days as processing_efficiency
    from returns_base
)

select
    return_id,
    return_number,
    order_id,
    customer_id,
    return_type,
    refund_method,
    status,
    total_return_amount,
    total_refund_amount_lines as total_refund_amount,
    return_line_count,
    requested_at,
    received_at,
    processed_at,
    days_to_receive,
    days_to_process,
    total_processing_days,
    refund_completion_rate,
    processing_efficiency
from with_timing
