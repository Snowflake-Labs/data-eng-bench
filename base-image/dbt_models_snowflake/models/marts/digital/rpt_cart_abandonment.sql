with carts as (
    select * from {{ ref('stg_digital__shopping_carts') }}
),

recent_carts as (
    select
        cart_id,
        session_id,
        customer_id,
        channel_id,
        status,
        item_count,
        subtotal,
        created_at,
        updated_at,
        converted_at,
        order_id,
        DATE_TRUNC(day, created_at) as cart_date,
        -- canonical status flags (MERGED, EXPIRED, ACTIVE, CONVERTED, ABANDONED)
        case when status = 'CONVERTED' or order_id is not null then true else false end as is_converted,
        case when status = 'ABANDONED' and order_id is null and converted_at is null then true else false end as is_abandoned,
        case when status = 'ACTIVE' then true else false end as is_active,
        case when status = 'EXPIRED' then true else false end as is_expired,
        case when status = 'MERGED' then true else false end as is_merged,
        DATEDIFF(second, created_at, coalesce(converted_at, updated_at)) as resolution_seconds
    from carts
    where updated_at >= DATEADD(day, -60, CURRENT_DATE)
),

channel_metrics as (
    select
        channel_id,
        count(cart_id) as total_carts,
        sum(case when is_merged then 1 else 0 end) as merged_carts,
        sum(case when is_expired then 1 else 0 end) as expired_carts,
        sum(case when is_active then 1 else 0 end) as active_carts,
        sum(case when is_converted then 1 else 0 end) as converted_carts,
        sum(case when is_abandoned then 1 else 0 end) as abandoned_carts,
        avg(item_count) as avg_items_per_cart,
        avg(subtotal) as avg_cart_value,
        SUM(CASE WHEN is_abandoned THEN item_count ELSE 0 END) as abandoned_items,
        SUM(CASE WHEN is_converted THEN item_count ELSE 0 END) as converted_items,
        AVG(CASE WHEN is_converted THEN resolution_seconds ELSE NULL END) as avg_time_to_convert_seconds,
        PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY CASE WHEN is_converted THEN resolution_seconds ELSE NULL END) as median_time_to_convert_seconds,
        count(distinct session_id) as unique_sessions
    from recent_carts
    group by channel_id
),

channel_rankings as (
    select
        channel_id,
        total_carts,
        converted_carts,
        abandoned_carts,
        avg_items_per_cart,
        avg_cart_value,
        abandoned_items,
        converted_items,
        avg_time_to_convert_seconds,
        median_time_to_convert_seconds,
        unique_sessions,
        round(100.0 * converted_carts / nullif(total_carts, 0), 2) as conversion_rate_percent,
        round(100.0 * abandoned_carts / nullif(total_carts, 0), 2) as abandonment_rate_percent,
        round(converted_carts::numeric / nullif(unique_sessions, 0), 4) as conversions_per_session,
        rank() over (order by round(100.0 * converted_carts / nullif(total_carts, 0), 2) desc) as conversion_rank
    from channel_metrics
)

select * from channel_rankings order by conversion_rank