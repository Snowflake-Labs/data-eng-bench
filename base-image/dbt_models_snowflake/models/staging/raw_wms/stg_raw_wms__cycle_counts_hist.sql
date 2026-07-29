with source as (
    select * from {{ source('raw_wms', 'cycle_counts_hist') }}
),

renamed as (
    select
        count_id as count_id,
        count_number as count_number,
        warehouse_id as warehouse_id,
        count_type as count_type,
        status as status,
        scheduled_date as scheduled_date,
        total_locations as total_locations,
        total_skus as total_skus,
        total_units_counted as total_units_counted,
        total_variance_units as total_variance_units,
        total_variance_value as total_variance_value,
        created_by as created_by,
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
