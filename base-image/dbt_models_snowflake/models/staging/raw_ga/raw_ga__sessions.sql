{{
    config(
        materialized='view',
        tags=['staging', 'ga']
    )
}}

with source as (
    select * from {{ source('ga', 'SESSIONS') }}
),

deduped as (
    select *
    from source
    where session_id is not null
    qualify row_number() over (partition by session_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
