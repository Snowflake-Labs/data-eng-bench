with source as (
    select * from {{ source('raw_ga', 'sessions') }}
),

renamed as (
    select
        session_id as session_id,
        visitor_id as visitor_id,
        customer_id as customer_id,
        channel_id as channel_id,
        session_start as session_start,
        session_end as session_end,
        duration_seconds as duration_seconds,
        page_views as page_views,
        landing_page as landing_page,
        exit_page as exit_page,
        referrer as referrer,
        utm_source as utm_source,
        utm_medium as utm_medium,
        utm_campaign as utm_campaign,
        device_type as device_type,
        browser as browser,
        os as os,
        ip_address as ip_address,
        country as country,
        is_converted as is_converted,
        order_id as order_id,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
