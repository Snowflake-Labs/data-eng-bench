{{
    config(
        materialized='view',
        tags=['staging', 'sfdc']
    )
}}

with source as (
    select * from {{ source('sfdc', 'ORDER_NOTES') }}
),

deduped as (
    select *
    from source
    where note_id is not null
    qualify row_number() over (partition by note_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
