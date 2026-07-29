with source as (
    select * from {{ source('raw_sfdc', 'campaign_members') }}
),

renamed as (
    select
        _id as _id,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _source_table as _source_table,
        _row_hash as _row_hash
    from source
)

select * from renamed
