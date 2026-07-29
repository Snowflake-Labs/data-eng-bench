{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.DIM_TIME

with source as (
    select * from {{ source('analytics', 'DIM_TIME') }}
),

renamed as (
    select
        time_key,
        full_time,
        hour,
        minute,
        second,
        trim(am_pm) as am_pm,
        hour_12,
        trim(time_of_day) as time_of_day
    from source
)

select * from renamed
