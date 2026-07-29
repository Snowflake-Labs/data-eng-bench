{{
    config(
        materialized='view',
        tags=['staging', 'sfdc']
    )
}}

with source as (
    select * from {{ source('sfdc', 'ACCOUNT_TIERS') }}
),

deduped as (
    select *
    from source
    where tier_id is not null
    qualify row_number() over (partition by tier_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
