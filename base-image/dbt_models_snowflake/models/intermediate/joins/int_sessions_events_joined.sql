{{
    config(
        materialized='view',
        tags=['intermediate', 'joins', 'ga4', 'web_analytics', 'high_volume'],
        meta={
            'owner': 'digital-analytics@company.com',
            'sla': '7:30am UTC',
            'estimated_runtime_minutes': 12,
            'snowflake_warehouse': 'TRANSFORM_L',
            'join_type': 'session_id',
            'fanout_expected': true,
            'estimated_row_count': 150000000,
            'downstream_dependencies': ['fct_sessions', 'fct_marketing_attribution']
        }
    )
}}

/*
================================================================================
Join model: int_sessions_events_joined
Joins: stg_ga__sessions <-> stg_ga__events on session_id
================================================================================

This is a HIGH VOLUME join model. Sessions x Events can produce 100M+ rows.
Consider downstream performance implications.

WARNING: LEFT JOIN produces fanout (one session -> many events)
This is intentional for event-level analysis.

PERFORMANCE NOTES:
- Uses L warehouse due to volume
- Consider filtering events in downstream models to reduce scan
- session_id is clustered in both source tables

Code Review Comments (preserved for context):
- Marcus (2023-09-01): "This join is expensive"
- Sarah (2023-09-01): "Unavoidable for attribution. Added clustering."
- Jake (2024-02-15): "t2_ prefix on columns is confusing"
- Sarah (2024-02-15): "Legacy naming, changing would break downstream models"
- Analytics (2024-08-01): "Can we add conversion_value to this join?"
- Sarah (2024-08-01): "That's in events table, already included as t2_*"
================================================================================
*/

WITH table1 AS (
    SELECT * FROM {{ ref('stg_ga__sessions') }}
),

table2 AS (
    SELECT * FROM {{ ref('stg_ga__events') }}
),

joined AS (
    SELECT
        t1.session_id AS session_id,
        t1.visitor_id AS visitor_id,
        t1.customer_id AS customer_id,
        t1.channel_id AS channel_id,
        t1.session_start AS session_start,
        t1.session_end AS session_end, t1.duration_seconds as duration_seconds,
        t1.page_views as page_views,
        t2.event_id AS t2_event_id,
        t2.event_type AS t2_event_type,
        t2.event_name AS t2_event_name,
        t2.event_timestamp AS t2_event_timestamp,
        t2.page_url AS t2_page_url,
        t2.element_id AS t2_element_id,
        t2.element_class as t2_element_class
    FROM table1 t1
    LEFT JOIN table2 t2 ON t1.session_id = t2.session_id
)

SELECT * FROM joined
