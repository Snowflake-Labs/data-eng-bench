with source as (
    select * from {{ source('raw_ga', 'audiences_hist') }}
),

renamed as (
    select
        segment_id as segment_id,
        segment_code as segment_code,
        segment_name as segment_name,
        segment_type as segment_type,
        segment_description as segment_description,
        segment_criteria as segment_criteria,
        is_dynamic as is_dynamic,
        refresh_frequency as refresh_frequency,
        last_refreshed_at as last_refreshed_at,
        member_count as member_count,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _archived_at as _archived_at
    from source
)

select * from renamed
