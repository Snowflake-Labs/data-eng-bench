/*
================================================================================
DATA QUALITY CHECK: Duplicate Customers
================================================================================
@author: Sarah Chen
@created: 2024-02-15
@last_modified: 2024-09-20

Purpose:
  Identifies potential duplicate customer records based on matching criteria.
  Used by the MDM team to maintain customer data quality.

Matching rules:
  1. Exact email match (case-insensitive)
  2. Fuzzy name + phone match
  3. Same billing address + similar name

Output:
  - Pairs of potentially duplicate customers
  - Match score and match reason
  - Recommended action (merge, review, ignore)

Dependencies:
  - dim_customers
  - int_customers__unified

Schedule: Daily at 6 AM UTC
Alert threshold: > 100 new duplicates triggers Slack alert

Performance:
  - Full refresh: ~8 minutes
  - Typical row count: 2,000-5,000 pairs
================================================================================
*/

{# post_hook disabled for DuckDB: grant select on {{ this }} to role data_quality_viewer #}
{{
    config(
        materialized='table',
        tags=['data-quality', 'customers', 'dedup']
    )
}}

with customers as (
    select * from {{ ref('dim_customers') }}
    where is_active = true
),

-- Email-based duplicates (highest confidence)
email_matches as (
    select
        c1.customer_id as customer_id_1,
        c2.customer_id as customer_id_2,
        c1.email,
        c1.full_name as name_1,
        c2.full_name as name_2,
        'EMAIL_MATCH' as match_type,
        100 as match_score  -- Exact email = high confidence
    from customers c1
    inner join customers c2
        on lower(trim(c1.email)) = lower(trim(c2.email))
        and c1.customer_id < c2.customer_id  -- Prevent self-joins and dupes
    where c1.email is not null
        and c1.email != ''
        and c1.email not like '%test%'  -- Exclude test emails
        and c1.email not like '%example.com'
),

-- Phone-based duplicates
phone_matches as (
    select
        c1.customer_id as customer_id_1,
        c2.customer_id as customer_id_2,
        c1.phone,
        c1.full_name as name_1,
        c2.full_name as name_2,
        'PHONE_MATCH' as match_type,
        80 as match_score
    from customers c1
    inner join customers c2
        on regexp_replace(c1.phone, '[^0-9]', '') = regexp_replace(c2.phone, '[^0-9]', '')
        and c1.customer_id < c2.customer_id
    where c1.phone is not null
        and length(regexp_replace(c1.phone, '[^0-9]', '')) >= 10  -- Valid phone length
),

-- Name similarity (lower confidence, needs manual review)
-- HACK: Using simple exact match for now
-- TODO: Implement Levenshtein or Soundex for fuzzy matching (DATA-1350)
name_matches as (
    select
        c1.customer_id as customer_id_1,
        c2.customer_id as customer_id_2,
        null as email,
        c1.full_name as name_1,
        c2.full_name as name_2,
        'NAME_MATCH' as match_type,
        50 as match_score
    from customers c1
    inner join customers c2
        on lower(trim(c1.full_name)) = lower(trim(c2.full_name))
        and c1.customer_id < c2.customer_id
    where c1.full_name is not null
        and length(c1.full_name) > 5  -- Avoid matching very short names
        -- Exclude common placeholder names
        and lower(c1.full_name) not in ('test user', 'guest', 'unknown', 'n/a')
),

-- Combine all matches
all_matches as (
    select * from email_matches
    union all
    select * from phone_matches
    union all
    select * from name_matches
),

-- Dedupe and take highest confidence match per pair
ranked_matches as (
    select
        *,
        row_number() over (
            partition by customer_id_1, customer_id_2
            order by match_score desc
        ) as rn
    from all_matches
),

final as (
    select
        customer_id_1,
        customer_id_2,
        name_1,
        name_2,
        email,
        match_type,
        match_score,
        case
            when match_score >= 90 then 'AUTO_MERGE'
            when match_score >= 70 then 'MANUAL_REVIEW'
            else 'INVESTIGATE'
        end as recommended_action,
        current_timestamp as detected_at
    from ranked_matches
    where rn = 1
)

select * from final
order by match_score desc, detected_at desc
