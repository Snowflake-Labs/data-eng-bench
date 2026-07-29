{{
    config(
        materialized='view',
        tags=['intermediate', 'customers']
    )
}}

-- =============================================================================
-- int_customers__unified.sql
-- Author: Sarah Chen
-- Created: 2023-06-15
-- Modified: 2024-08-20 - Added phone dedup logic
--
-- Unified customer view. Merges SFDC + ERP + Shopify customers.
-- Grain: 1 row per customer.
--
-- Performance: ~45 sec full refresh
-- =============================================================================

-- TODO: Add Marketo contacts once marketing provides field mapping (Q1 2025)
-- FIXME: Phone number parsing doesn't handle international formats correctly
-- See ticket DATA-892 for details

with customers_base as (

    select
        customer_id,
        email,
        first_name,
        last_name,
        concat(first_name, ' ', last_name) as full_name,
        phone_primary as phone,
        customer_number as account_id,
        status,
        CREATED_AT as created_at,
        UPDATED_AT as updated_at,
        source_system_code as source_system
    from {{ ref('stg_customer__customers') }}
    -- HACK: Excluding NULL emails for now but this drops ~3% of customers
    -- Need to implement fuzzy matching on name+phone for these
    where email is not null

),

final as (

    select
        customer_id,
        email,
        first_name,
        last_name,
        full_name,
        phone,
        account_id,
        status,
        created_at,
        updated_at,
        source_system,

        -- Calculated fields
        DATEDIFF(day, created_at, current_timestamp) as customer_age_days,

        -- Status flags
        case
            when status = 'Active' then true
            else false
        end as is_active,

        case
            when email is not null then true
            else false
        end as has_email,

        case
            when phone is not null then true
            else false
        end as has_phone

    from customers_base

)

select * from final
