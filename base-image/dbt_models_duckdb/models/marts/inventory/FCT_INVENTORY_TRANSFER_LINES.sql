-- Inventory Transfer Line Details
-- Details of transfer lines

with inventory_transfer_lines as (
    select * from {{ ref('stg_inventory__inventory_transfer_lines') }}
),

inventory_transfers as (
    select * from {{ ref('stg_inventory__inventory_transfers') }}
)

select
    itl.transfer_line_id,
    itl.transfer_id,
    it.status as transfer_status,
    itl.variant_id,
    itl.quantity_requested,
    itl.quantity_shipped,
    itl.quantity_received,
    itl.quantity_requested - itl.quantity_received as variance,
    round(100.0 * itl.quantity_received / nullif(itl.quantity_requested, 0), 2) as fulfillment_rate
from inventory_transfer_lines itl
left join inventory_transfers it on itl.transfer_id = it.transfer_id
