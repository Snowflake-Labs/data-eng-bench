-- Channel Configuration Summary
-- Summarizes channel configurations

with channel_configurations as (
    select * from {{ ref('stg_digital__channel_configurations') }}
),

sales_channels as (
    select * from {{ ref('stg_digital__sales_channels') }}
)

select
    sc.channel_name,
    sc.channel_type,
    count(distinct cc.config_id) as config_count,
    count(distinct cc.config_key) as unique_config_keys
from channel_configurations cc
left join sales_channels sc on cc.channel_id = sc.channel_id
group by 1, 2
