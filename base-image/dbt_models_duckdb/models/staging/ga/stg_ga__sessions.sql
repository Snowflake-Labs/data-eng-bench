{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.SESSIONS
 *
 * Entity Type: table
 * Source: GA - RAW_GA.SESSIONS
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per sessions
 */

with source as (

    select * from {{ source('ga', 'SESSIONS') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        session_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(visitor_id) as visitor_id,
        trim(customer_id) as customer_id,
        trim(channel_id) as channel_id,
        trim(session_start) as session_start,
        trim(session_end) as session_end,
        duration_seconds as duration_seconds,
        page_views as page_views,
        trim(landing_page) as landing_page,
        trim(exit_page) as exit_page,
        trim(referrer) as referrer,
        trim(utm_source) as utm_source,
        trim(utm_medium) as utm_medium,
        trim(utm_campaign) as utm_campaign,
        trim(device_type) as device_type,
        trim(browser) as browser,
        trim(os) as os,
        trim(ip_address) as ip_address,
        trim(country) as country,
        is_converted as is_converted,
        trim(order_id) as order_id,
        created_at as created_at,

        /*
         * Metadata Columns
         */
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash

    from source

)

select * from renamed
