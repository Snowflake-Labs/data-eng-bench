with source as (
    select * from {{ source('raw_legacy', 'ctrycod_stg') }}
),

renamed as (
    select
        country_id as country_id,
        country_code_2 as country_code_2,
        country_name as country_name,
        continent as continent,
        currency_code as currency_code,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        TRIM("_status") AS _status
    from source
)

select * from renamed
