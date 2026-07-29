with source as (
    select * from {{ source('raw_sfdc', 'order_notes_hist') }}
),

renamed as (
    select
        note_id as note_id,
        order_id as order_id,
        note_type as note_type,
        note_text as note_text,
        is_internal as is_internal,
        created_by as created_by,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
