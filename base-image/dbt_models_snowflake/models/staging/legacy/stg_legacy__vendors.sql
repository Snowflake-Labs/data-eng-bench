{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'reference', 'vendors'],
        unique_key=['vendor_id']
    )
}}

/*
    Staging model: stg_legacy__vendors
    Grain: Per vendor
    Unique Key: vendor_id
    Source: RAW_LEGACY.VENDMST (Vendor Master)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__vendmst') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        _id as vendor_id,

        -- Relationships
        substr(_id, 1, 5) as country_id,
        substr(_id, 6, 8) as vendor_category_id,

        -- Vendor Details (derived/placeholder)
        'VENDOR-' || substr(_id, 1, 8) as vendor_code,
        'Vendor ' || substr(_id, 1, 8) || ' Inc.' as vendor_name,
        case
            when abs(hash(_id)) % 4 = 0 then 'MANUFACTURER'
            when abs(hash(_id)) % 4 = 1 then 'DISTRIBUTOR'
            when abs(hash(_id)) % 4 = 2 then 'WHOLESALER'
            else 'SUPPLIER'
        end as vendor_type,

        -- Contact Information
        substr(_id, 1, 5) || ' Main Street' as address_line1,
        'Suite ' || (abs(hash(_id)) % 999 + 1) as address_line2,
        'City-' || substr(_id, 1, 5) as city,
        substr(_id, 1, 2) as state,
        lpad(cast(abs(hash(_id)) % 99999 as varchar), 5, '0') as postal_code,
        'contact@vendor' || substr(_id, 1, 8) || '.com' as email,
        '+1-' || lpad(cast(abs(hash(_id)) % 999 as varchar), 3, '0') || '-' || lpad(cast(abs(hash(_id)) % 9999 as varchar), 4, '0') as phone,

        -- Financial Terms
        case
            when abs(hash(_id)) % 3 = 0 then 'NET30'
            when abs(hash(_id)) % 3 = 1 then 'NET60'
            else 'NET90'
        end as payment_terms,
        'USD' as default_currency,
        abs(hash(_id)) % 50000 + 10000.00 as credit_limit,

        -- Flags
        case when abs(hash(_id)) % 10 < 9 then true else false end as is_active,
        case when abs(hash(_id)) % 5 = 0 then true else false end as is_preferred,

        -- Metadata
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
