-- fct_reconstructed_sessions
-- Session reconstruction from raw web events
-- @author: Digital Analytics Team
--
-- Why "reconstructed"? Because the original session tracking was broken.
-- GA lost sessions due to cookie consent changes, so we rebuild them
-- from raw events using a 30-minute inactivity timeout.
--
-- This is a HACK but it works. Sort of. Most of the time.
--
-- Performance: 8 min (window functions on 50M events)
-- Memory: Uses 128GB, don't run with anything else
--
-- FIXME: 30-min timeout is arbitrary. Should be configurable.
-- TODO: Handle cross-device sessions (currently creates duplicate sessions)
-- BUG: Midnight boundary causes session splits. Known issue.

with events as (
    select
        session_id,
        event_timestamp,
        -- HACK: LAG is expensive but necessary for gap detection
        lag(event_timestamp) over (partition by session_id order by event_timestamp) as prev_event_ts
    from {{ ref('stg_digital__web_events') }}
),
session_flags as (
    select 
        session_id,
        event_timestamp,
        case 
            when prev_event_ts is null or (event_timestamp - prev_event_ts) > interval '30 minutes' then 1 
            else 0 
        end as new_session_flag
    from events
)

select 
    session_id,
    event_timestamp,
    sum(new_session_flag) over (partition by session_id order by event_timestamp) as reconstructed_session_id
from session_flags