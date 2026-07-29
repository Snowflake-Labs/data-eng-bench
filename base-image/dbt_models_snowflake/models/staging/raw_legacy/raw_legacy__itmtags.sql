{{
    config(
        materialized='view',
        tags=['staging', 'legacy']
    )
}}

with source as (
    select * from {{ source('legacy', 'ITMTAGS') }}
),

deduped as (
    select *
    from source
    where tag_id is not null
    qualify row_number() over (partition by tag_id order by _loaded_at desc NULLS LAST) = 1
)

select * from deduped
