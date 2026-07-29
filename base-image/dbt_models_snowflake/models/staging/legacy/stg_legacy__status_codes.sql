{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'reference', 'status_codes'],
        unique_key=['status_code_id']
    )
}}

/*
    Staging model: stg_legacy__status_codes
    Grain: Per status code (per entity type)
    Unique Key: status_code_id
    Source: RAW_LEGACY.STSCOD (Status Codes)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__stscod') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(status_code_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        status_code_id,

        -- Status Attributes
        entity_type,
        status_code,
        status_name,
        status_description,
        {{ safe_cast('display_order', 'integer') }} as display_order,

        -- Flags
        {{ safe_cast('is_terminal', 'boolean') }} as is_terminal,
        {{ safe_cast('is_active', 'boolean') }} as is_active,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,
        {{ standardize_date('updated_at') }} as updated_at,

        -- Metadata
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
