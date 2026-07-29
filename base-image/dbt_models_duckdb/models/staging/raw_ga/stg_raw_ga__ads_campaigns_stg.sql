with source as (
    select * from {{ source('raw_ga', 'ads_campaigns_stg') }}
),

renamed as (
    select
        _id as _id,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _source_table as _source_table,
        _row_hash as _row_hash,
        _status as _status
    from source
)

select * from renamed
