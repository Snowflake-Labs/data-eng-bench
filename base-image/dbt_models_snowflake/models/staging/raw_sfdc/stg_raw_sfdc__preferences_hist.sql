with source as (
    select * from {{ source('raw_sfdc', 'preferences_hist') }}
),

renamed as (
    select
        preference_id as preference_id,
        customer_id as customer_id,
        preference_category as preference_category,
        preference_key as preference_key,
        preference_value as preference_value,
        is_opted_in as is_opted_in,
        effective_from as effective_from,
        effective_to as effective_to,
        source as source,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id, _row_number as _row_number,
        _row_hash as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
