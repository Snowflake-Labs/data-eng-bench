{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'reference', 'countries'],
        unique_key=['country_id']
    )
}}

/*
    Staging model: stg_legacy__countries
    Grain: Per country
    Unique Key: country_id
    Source: RAW_LEGACY.CTRYCOD (Country Codes)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__ctrycod') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(country_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        country_id,

        -- Country Attributes
        country_code_2,
        country_name,
        continent,
        currency_code,

        -- Flags
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
