with source as (
    select * from {{ source('raw_ga', 'events') }}
),

renamed as (
    select
        event_id as event_id,
        session_id as session_id,
        event_type as event_type,
        event_name as event_name,
        event_timestamp as event_timestamp,
        page_url as page_url,
        element_id as element_id,
        element_class as element_class,
        product_id as product_id,
        event_value as event_value,
        event_data as event_data,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
