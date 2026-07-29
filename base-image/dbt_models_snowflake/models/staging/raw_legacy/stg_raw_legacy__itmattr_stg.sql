with source as (
    select * from {{ source('raw_legacy', 'itmattr_stg') }}
),

renamed as (
    select
        attribute_id as attribute_id,
        attribute_code as attribute_code,
        attribute_name as attribute_name,
        attribute_description as attribute_description,
        attribute_type as attribute_type,
        data_type as data_type,
        is_variant_attribute as is_variant_attribute,
        is_filterable as is_filterable,
        is_searchable as is_searchable,
        is_comparable as is_comparable,
        is_required as is_required,
        default_value as default_value,
        validation_regex as validation_regex,
        min_value as min_value,
        max_value as max_value,
        display_order as display_order,
        attribute_group as attribute_group,
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
