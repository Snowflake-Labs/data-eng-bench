{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'reference', 'gl_accounts'],
        unique_key=['gl_account_id']
    )
}}

/*
    Staging model: stg_legacy__gl_accounts
    Grain: Per GL account
    Unique Key: gl_account_id
    Source: RAW_LEGACY.GLACCT (General Ledger Accounts)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__glacct') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        _id as gl_account_id,

        -- Account Hierarchy
        substr(_id, 1, 4) as parent_account_id,

        -- Account Details (derived/placeholder)
        substr(_id, 1, 10) as account_number,
        'Account ' || substr(_id, 1, 10) as account_name,
        case
            when substr(_id, 1, 1) = '1' then 'ASSETS'
            when substr(_id, 1, 1) = '2' then 'LIABILITIES'
            when substr(_id, 1, 1) = '3' then 'EQUITY'
            when substr(_id, 1, 1) = '4' then 'REVENUE'
            when substr(_id, 1, 1) = '5' then 'EXPENSES'
            else 'OTHER'
        end as account_type,
        case
            when substr(_id, 1, 2) in ('10', '11') then 'CURRENT_ASSETS'
            when substr(_id, 1, 2) in ('12', '13') then 'FIXED_ASSETS'
            when substr(_id, 1, 2) in ('20', '21') then 'CURRENT_LIABILITIES'
            when substr(_id, 1, 2) in ('22', '23') then 'LONG_TERM_LIABILITIES'
            when substr(_id, 1, 2) in ('40', '41') then 'OPERATING_REVENUE'
            when substr(_id, 1, 2) in ('50', '51') then 'OPERATING_EXPENSES'
            else 'OTHER'
        end as account_category,

        -- Flags
        case when abs(HASH(_id)) % 10 < 9 then true else false end as is_active,
        case when substr(_id, 1, 1) in ('4', '5') then true else false end as is_profit_loss,
        case when substr(_id, 1, 1) in ('1', '2', '3') then true else false end as is_balance_sheet,

        -- Metadata
        _loaded_at,
        _source_system,
        _source_table,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
