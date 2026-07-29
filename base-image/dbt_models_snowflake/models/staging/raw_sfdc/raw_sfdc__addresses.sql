{{
    config(
        materialized='view',
        tags=['staging', 'sfdc']
    )
}}

with source as (
    select * from {{ source('sfdc', 'ADDRESSES') }}
),

deduped as (
    select *
    from source
    where address_id is not null
    qualify row_number() over (partition by address_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
