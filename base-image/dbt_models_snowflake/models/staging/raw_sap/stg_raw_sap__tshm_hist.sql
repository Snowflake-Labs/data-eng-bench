with source as (
    select * from {{ source('raw_sap', 'tshm_hist') }}
),

renamed as (
    select
        shipping_method_id as shipping_method_id,
        shipping_method_code as shipping_method_code,
        shipping_method_name as shipping_method_name,
        carrier_id as carrier_id,
        estimated_days_min as estimated_days_min,
        estimated_days_max as estimated_days_max,
        is_express as is_express,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
