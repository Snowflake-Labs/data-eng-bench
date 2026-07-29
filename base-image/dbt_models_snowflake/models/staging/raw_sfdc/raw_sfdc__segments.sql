{{
    config(
        materialized='view',
        tags=['staging', 'sfdc']
    )
}}

with source as (
    select * from {{ source('sfdc', 'SEGMENTS') }}
),

deduped as (
    select *
    from source
    where segment_id is not null
    qualify row_number() over (partition by segment_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
