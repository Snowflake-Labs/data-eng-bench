{{
    config(
        materialized='view',
        tags=['staging', 'sap', 'vendor', 'master_data'],
        unique_key=['vendor_id']
    )
}}

/*
    Staging model: stg_sap__vendors
    Grain: Per vendor
    Unique Key: vendor_id
    Links: lfa1 (vendor master), eina (vendor/product relationships), vendor_eval (performance)
    Purpose: Vendor master with sourcing strategy and performance metrics
*/

with raw_data as (
    select *
    from {{ ref('raw_sap__lfa1') }}
    where _id is not null
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

        -- Vendor Identifiers (derived from UUID)
        'VEND-' || replace(substr(_id, 1, 8), '-', '') as vendor_code,
        'Vendor ' || replace(substr(_id, 1, 8), '-', '') as vendor_name,

        -- Vendor Type (hash-based derivation)
        case abs(hash(_id)) % 5
            when 0 then 'MANUFACTURER'
            when 1 then 'DISTRIBUTOR'
            when 2 then 'WHOLESALER'
            when 3 then 'RESELLER'
            else 'SERVICES'
        end as vendor_type,

        -- Vendor Status (hash-based derivation)
        case abs(hash(_id || 'status')) % 3
            when 0 then 'ACTIVE'
            when 1 then 'INACTIVE'
            else 'BLOCKED'
        end as vendor_status,

        -- Sourcing Strategy (hash-based derivation)
        case abs(hash(_id || 'sourcing')) % 3
            when 0 then 'PRIMARY_SOURCE'
            when 1 then 'SECONDARY_SOURCE'
            else 'BACKUP_SOURCE'
        end as sourcing_status,
        case when abs(hash(_id || 'preferred')) % 4 = 0 then true else false end as is_preferred_vendor,
        case when abs(hash(_id || 'sole')) % 5 = 0 then true else false end as is_sole_source,
        case when abs(hash(_id || 'strategic')) % 3 = 0 then true else false end as is_strategic_vendor,

        -- Financial Profile (hash-based derivation)
        abs(hash(_id || 'spend')) % 9000000 + 100000 as annual_spend_amount,
        abs(hash(_id || 'invoice')) % 90000 + 1000 as avg_invoice_amount,
        abs(hash(_id || 'orders')) % 500 + 10 as total_active_orders,

        -- Payment Terms (hash-based derivation)
        case abs(hash(_id || 'payment')) % 4
            when 0 then 'NET30'
            when 1 then 'NET60'
            when 2 then 'NET90'
            else 'COD'
        end as payment_terms_code,
        cast((abs(hash(_id || 'discount')) % 300) / 100.0 as decimal(5,2)) as early_payment_discount_pct,

        -- Quality & Compliance (derived)
        case
            when abs(hash(_id)) % 100 > 85 then 'EXCELLENT'
            when abs(hash(_id)) % 100 > 70 then 'GOOD'
            when abs(hash(_id)) % 100 > 50 then 'ACCEPTABLE'
            else 'NEEDS_IMPROVEMENT'
        end as quality_rating,
        abs(hash(_id)) % 5 as defect_rate_pct,
        abs(hash(_id)) % 7 + 1 as on_time_delivery_days_avg,
        abs(hash(_id)) % 100 as compliance_score,

        -- Contact Information (derived from UUID)
        'vendor' || replace(substr(_id, 1, 8), '-', '') || '@vendor.com' as contact_email,
        '+1' || replace(replace(substr(_id, 1, 13), '-', ''), 'a', '0') as contact_phone,

        -- Location Hierarchy (hash-based)
        'REG-' || lpad(cast(abs(hash(_id || 'region')) % 100 as varchar), 3, '0') as region_code,
        'CNTRY-' || lpad(cast(abs(hash(_id || 'country')) % 200 as varchar), 3, '0') as country_code,
        'CITY-' || lpad(cast(abs(hash(_id || 'city')) % 500 as varchar), 3, '0') as city_code,

        -- Capacity & Lead Time (derived)
        abs(hash(_id)) % 10000 + 1000 as monthly_capacity_units,
        abs(hash(_id)) % 60 + 5 as lead_time_days,
        abs(hash(_id)) % 30 + 1 as minimum_order_quantity,

        -- Certifications (derived)
        case when abs(hash(_id)) % 3 = 0 then true else false end as has_iso_certification,
        case when abs(hash(_id)) % 4 = 0 then true else false end as has_quality_cert,
        case when abs(hash(_id)) % 5 = 0 then true else false end as has_environmental_cert,

        -- Metadata
        _loaded_at,
        _source_system,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
order by vendor_id
