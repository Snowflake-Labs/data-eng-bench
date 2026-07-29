with source as (
    select * from {{ source('raw_sfdc', 'contacts_hist') }}
),

renamed as (
    select
        contact_id as contact_id,
        customer_id as customer_id,
        contact_type as contact_type,
        contact_subtype as contact_subtype,
        contact_value as contact_value,
        is_primary as is_primary,
        is_verified as is_verified,
        verified_at as verified_at,
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
