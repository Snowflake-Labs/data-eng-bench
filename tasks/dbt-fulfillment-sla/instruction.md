# Order Fulfillment SLA Analysis

Build a comprehensive fulfillment performance analytics suite that measures delivery times, SLA compliance, carrier performance, and warehouse efficiency. This includes analyzing processing delays, transit times, identifying performance patterns, and comparing carriers across different order value tiers.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)

### Snowflake
- Set `DB_TYPE=snowflake`
- Environment variables (pre-configured):
  - `SNOWFLAKE_ACCOUNT`
  - `SNOWFLAKE_USER`
  - `SNOWFLAKE_PASSWORD`
  - `SNOWFLAKE_DATABASE` - The clone database to use
  - `SNOWFLAKE_SCHEMA`
  - `SNOWFLAKE_WAREHOUSE`
  - `SNOWFLAKE_ROLE` (optional)

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.

## Environment

- **dbt project locations**:
  - DuckDB: `/app/dbt_models_duckdb`
  - Snowflake: `/app/dbt_models_snowflake`
- **Analysis period**: January 1, 2023 through November 30, 2024

## Source Data

The staging layer provides these tables. Explore them to understand available columns:

- `stg_orders__orders`: Order header data including identifiers, timestamps (ordered_at, shipped_at, delivered_at), monetary amounts, status, warehouse assignment, carrier info, and order flags.
- `stg_orders__shipments`: Shipment-level detail with warehouse, carrier, shipping method, tracking, status, timestamps, cost and weight.
- `stg_wms__ship_methods`: Shipping method reference data with codes, names, carrier assignment, estimated delivery windows, and express flag.
- `stg_wms__warehouses`: Warehouse reference data with codes, names, types, and location information.
- `stg_reference__carriers`: Carrier reference data with codes, names, and types.

## Requirements

### Data Rules

**Order Filtering:**
Only include orders that are:
- Status is 'DELIVERED' (we can only measure SLA for completed deliveries)
- Not a test order (test_order_flag is not 1 or true)
- Within the analysis period (ordered_at >= '2023-01-01' and ordered_at < '2024-12-01')
- Has valid timestamps: ordered_at, shipped_at, and delivered_at are all NOT NULL
- Has positive time intervals: shipped_at > ordered_at AND delivered_at > shipped_at

**Shipment Filtering:**
Only include shipments where:
- shipping_method_id is NOT NULL (required for SLA calculation)
- warehouse_id is NOT NULL (required for aggregation)
- carrier_id is NOT NULL (required for carrier metrics)
- The associated shipping method has estimated_days_min and estimated_days_max NOT NULL (required for SLA classification)

**Join Strategy:**
Use INNER JOINs between orders, shipments, ship_methods, warehouses, and carriers to ensure all required fields are present. This naturally filters out records with NULL foreign keys. Join the carriers table using the carrier_id from ship_methods (not from shipments) to ensure carrier_name is consistent for each shipping_method_id.

**Aggregation Grain:**
Each shipment is counted separately. If an order has multiple shipments, each shipment contributes to the metrics independently. The combination of (fulfillment_month, shipping_method_id, warehouse_id) should be unique in the fulfillment_sla output.

### Models to Create

Create these dbt models:

1. **Intermediate models** in `models/intermediate/`:
   - `int_shipment_times`: Calculate time intervals for each delivered shipment with all relevant details.

2. **Mart models** in `models/marts/analytics/`:
   - `fulfillment_sla`: Monthly SLA metrics by shipping method and warehouse (table)
   - `carrier_performance`: Carrier-level performance comparison with rankings (table)
   - `warehouse_performance`: Warehouse-level performance comparison with rankings (table)
   - `fulfillment_summary`: High-level summary by carrier and service tier (table)

### Time Interval Calculations

For each shipment, calculate these intervals in days (use `DATEDIFF('day', start, end)`):

- **processing_days**: Days from ordered_at to shipped_at (warehouse processing time)
- **transit_days**: Days from shipped_at to delivered_at (carrier transit time)
- **total_days**: Days from ordered_at to delivered_at (end-to-end fulfillment time)

### Order Value Tiers

Classify orders by grand_total into value tiers:
- **Budget**: grand_total < 50
- **Standard**: grand_total >= 50 AND grand_total < 150
- **Premium**: grand_total >= 150

### SLA Compliance

Determine SLA compliance by comparing transit_days to the shipping method's estimated_days_max:

**On-Time Classification:**
- **Early**: transit_days < estimated_days_min
- **On-Time**: transit_days >= estimated_days_min AND transit_days <= estimated_days_max
- **Late**: transit_days > estimated_days_max

**Breach Severity** (for late deliveries only):
- **Minor**: 1-2 days late (transit_days > estimated_days_max AND transit_days <= estimated_days_max + 2)
- **Major**: 3-7 days late (transit_days > estimated_days_max + 2 AND transit_days <= estimated_days_max + 7)
- **Severe**: >7 days late (transit_days > estimated_days_max + 7)
- **None**: Not late (on_time_status != 'Late')

### Delay Attribution

Identify where delays occurred:

- **warehouse_delay**: processing_days > 2 (standard processing SLA is 2 days)
- **carrier_delay**: transit_days > estimated_days_max
- **delay_attribution**:
  - 'Warehouse Only': warehouse_delay = true AND carrier_delay = false
  - 'Carrier Only': warehouse_delay = false AND carrier_delay = true
  - 'Both': warehouse_delay = true AND carrier_delay = true
  - 'None': warehouse_delay = false AND carrier_delay = false

### Fulfillment SLA Metrics

For each combination of fulfillment_month (YYYY-MM format from ordered_at), shipping_method_id, and warehouse_id, calculate:

**Dimensional Columns (carried from joins):**
- **shipping_method_name**: Name of the shipping method (from ship_methods)
- **warehouse_name**: Name of the warehouse (from warehouses)
- **carrier_name**: Name of the carrier (from carriers, joined via ship_methods)
- **is_express**: Whether the shipping method is express (from ship_methods, integer 1/0)
- **estimated_days_min**: Minimum estimated delivery days (from ship_methods)
- **estimated_days_max**: Maximum estimated delivery days (from ship_methods)

**Volume Metrics:**
- **total_shipments**: Count of shipments
- **total_order_value**: Sum of grand_total

**Time Metrics (in days):**
- **avg_processing_days**: Average processing time
- **avg_transit_days**: Average transit time
- **avg_total_days**: Average end-to-end fulfillment time
- **p50_total_days**: Median fulfillment time (use PERCENTILE_CONT(0.5))
- **p75_total_days**: 75th percentile fulfillment time
- **p90_total_days**: 90th percentile fulfillment time
- **p95_total_days**: 95th percentile fulfillment time
- **min_total_days**: Minimum fulfillment time
- **max_total_days**: Maximum fulfillment time

**SLA Compliance Metrics:**
- **early_count**: Shipments delivered early
- **ontime_count**: Shipments delivered on-time
- **late_count**: Shipments delivered late
- **early_pct**: Percentage delivered early
- **ontime_pct**: Percentage delivered on-time
- **late_pct**: Percentage delivered late
- **sla_compliance_rate**: (early_count + ontime_count) / total_shipments * 100

**Breach Analysis:**
- **minor_breach_count**: Count of minor breaches
- **major_breach_count**: Count of major breaches
- **severe_breach_count**: Count of severe breaches
- **avg_days_late**: Average of (transit_days - estimated_days_max) for late shipments only (NULL if no late shipments)

**Delay Attribution:**
- **warehouse_delay_count**: Shipments with warehouse delays
- **carrier_delay_count**: Shipments with carrier delays
- **both_delay_count**: Shipments with both delays
- **warehouse_delay_pct**: Percentage with warehouse delays
- **carrier_delay_pct**: Percentage with carrier delays

**Value Tier Breakdown:**
- **budget_shipments**: Count of Budget tier shipments
- **standard_shipments**: Count of Standard tier shipments
- **premium_shipments**: Count of Premium tier shipments
- **budget_sla_rate**: SLA compliance rate for Budget tier (NULL if 0 shipments)
- **standard_sla_rate**: SLA compliance rate for Standard tier (NULL if 0 shipments)
- **premium_sla_rate**: SLA compliance rate for Premium tier (NULL if 0 shipments)

**Performance Flags:**
- **is_peak_month**: true if month is November or December (holiday season)
- **month_over_month_volume_change_pct**: Percentage change in total_shipments from previous month for same shipping_method/warehouse (NULL for first month). Calculate as ((current - previous) / previous) * 100.

### Carrier Performance Metrics

For each carrier (carrier_id), calculate overall performance metrics. Include the following dimensional columns:
- **carrier_id**: Carrier identifier
- **carrier_code**: Carrier code (from carriers reference table)
- **carrier_name**: Carrier name (from carriers reference table)
- **carrier_type**: Carrier type (from carriers reference table)

**Volume Metrics:**
- **total_shipments**: Count of shipments
- **total_order_value**: Sum of grand_total
- **unique_orders**: Count of distinct orders
- **avg_shipment_value**: total_order_value / total_shipments

**Time Metrics:**
- **avg_processing_days**: Average processing time
- **avg_transit_days**: Average transit time
- **avg_total_days**: Average total fulfillment time
- **p50_transit_days**: Median transit time
- **p95_transit_days**: 95th percentile transit time
- **transit_time_std_dev**: Standard deviation of transit_days (consistency metric)

**SLA Metrics:**
- **sla_compliance_rate**: Percentage meeting SLA
- **early_delivery_rate**: Percentage delivered early
- **severe_breach_rate**: Percentage with severe breaches

**Value Tier Performance:**
- **budget_shipments**: Budget tier volume
- **standard_shipments**: Standard tier volume
- **premium_shipments**: Premium tier volume
- **budget_sla_rate**: Budget tier SLA rate
- **standard_sla_rate**: Standard tier SLA rate
- **premium_sla_rate**: Premium tier SLA rate
- **premium_to_budget_sla_diff**: premium_sla_rate - budget_sla_rate (positive = better premium service)

**Express vs Standard:**
- **express_shipments**: Count of shipments where is_express = true
- **standard_shipping_shipments**: Count of shipments where is_express = false OR is_express IS NULL (treat NULL as non-express)
- **express_sla_rate**: SLA rate for express shipments (NULL if none)
- **standard_shipping_sla_rate**: SLA rate for non-express shipments (NULL if none)

Note: express_shipments + standard_shipping_shipments must equal total_shipments.

**Carrier Ranking:**

Calculate composite scores and rankings:

- **speed_score**: 100 - (avg_total_days * 5), capped at 0-100. Lower avg time = higher score.
- **reliability_score**: sla_compliance_rate (already 0-100)
- **consistency_score**: 100 - (transit_time_std_dev * 10), capped at 0-100. Lower variability = higher score.
- **composite_score**: (speed_score * 0.3) + (reliability_score * 0.5) + (consistency_score * 0.2)
- **volume_weighted_score**: composite_score * (1 + ln(total_shipments) / 10). Natural log of volume adds bonus for high-volume carriers. Round to 1 decimal.
- **carrier_rank**: Rank by composite_score descending (1 = best). Use carrier_id as secondary sort to break ties, ensuring consecutive ranks with no gaps.
- **rank_within_type**: Rank within the same carrier_type by composite_score descending. Use carrier_id as secondary sort. Carriers of the same type compete against each other (1 = best within type).

**Performance Classification:**
- **performance_tier**: Based on composite_score:
  - 'Elite': composite_score >= 85
  - 'Strong': composite_score >= 70 and < 85
  - 'Average': composite_score >= 55 and < 70
  - 'Underperforming': composite_score < 55

**Trend Analysis:**
- **first_shipment_date**: Date of first shipment for this carrier
- **last_shipment_date**: Date of last shipment for this carrier
- **active_months**: Count of distinct months with shipments
- **recent_trend**: Compare last 3 months SLA rate vs prior 3 months. 'Improving' if recent > prior + 2, 'Declining' if recent < prior - 2, 'Stable' otherwise. NULL if fewer than 6 months of data.

### Warehouse Performance Metrics

For each warehouse (warehouse_id), calculate overall performance metrics. Include the following dimensional columns:
- **warehouse_id**: Warehouse identifier
- **warehouse_code**: Warehouse code (from warehouses reference table)
- **warehouse_name**: Warehouse name (from warehouses reference table)
- **warehouse_type**: Warehouse type (from warehouses reference table)
- **state_province**: State/province of the warehouse (from warehouses reference table)
- **country_code**: Country code of the warehouse (from warehouses reference table)

**Volume Metrics:**
- **total_shipments**: Count of shipments
- **total_order_value**: Sum of grand_total
- **unique_orders**: Count of distinct orders
- **avg_shipment_value**: total_order_value / total_shipments

**Time Metrics:**
- **avg_processing_days**: Average processing time (warehouse responsibility)
- **avg_transit_days**: Average transit time
- **avg_total_days**: Average total fulfillment time
- **p50_processing_days**: Median processing time
- **p95_processing_days**: 95th percentile processing time
- **processing_time_std_dev**: Standard deviation of processing_days (consistency metric)

**SLA Metrics:**
- **sla_compliance_rate**: Percentage meeting SLA
- **early_delivery_rate**: Percentage delivered early
- **severe_breach_rate**: Percentage with severe breaches
- **warehouse_caused_delay_rate**: Percentage where warehouse_delay = true

**Value Tier Performance:**
- **budget_shipments**: Budget tier volume
- **standard_shipments**: Standard tier volume
- **premium_shipments**: Premium tier volume
- **budget_sla_rate**: Budget tier SLA rate
- **standard_sla_rate**: Standard tier SLA rate
- **premium_sla_rate**: Premium tier SLA rate
- **premium_to_budget_sla_diff**: premium_sla_rate - budget_sla_rate (positive = better premium service)

**Carrier Mix:**
- **distinct_carriers**: Count of distinct carriers used by this warehouse
- **primary_carrier_name**: Name of the carrier with most shipments at this warehouse. If tied, use the carrier_name that comes first alphabetically.
- **primary_carrier_pct**: Percentage of shipments handled by primary carrier

**Warehouse Ranking:**

Calculate composite scores and rankings:

- **efficiency_score**: 100 - (avg_processing_days * 20), capped at 0-100. Lower processing time = higher score. Warehouses should ship within 2 days ideally.
- **reliability_score**: sla_compliance_rate (already 0-100)
- **consistency_score**: 100 - (processing_time_std_dev * 20), capped at 0-100. Lower variability = higher score.
- **composite_score**: (efficiency_score * 0.4) + (reliability_score * 0.4) + (consistency_score * 0.2)
- **volume_weighted_score**: composite_score * (1 + ln(total_shipments) / 10). Natural log of volume adds bonus for high-volume warehouses. Round to 1 decimal.
- **warehouse_rank**: Rank by composite_score descending (1 = best). Use warehouse_id as secondary sort to break ties, ensuring consecutive ranks with no gaps.
- **rank_within_type**: Rank within the same warehouse_type by composite_score descending. Use warehouse_id as secondary sort. Warehouses of the same type compete against each other (1 = best within type).

**Performance Classification:**
- **performance_tier**: Based on composite_score:
  - 'Elite': composite_score >= 85
  - 'Strong': composite_score >= 70 and < 85
  - 'Average': composite_score >= 55 and < 70
  - 'Underperforming': composite_score < 55

**Trend Analysis:**
- **first_shipment_date**: Date of first shipment for this warehouse
- **last_shipment_date**: Date of last shipment for this warehouse
- **active_months**: Count of distinct months with shipments
- **recent_trend**: Compare last 3 months SLA rate vs prior 3 months. 'Improving' if recent > prior + 2, 'Declining' if recent < prior - 2, 'Stable' otherwise. NULL if fewer than 6 months of data.

### Fulfillment Summary

Aggregate metrics by carrier_name and service_tier (Express vs Standard based on is_express flag):

- **carrier_name**: Carrier name
- **service_tier**: 'Express' if is_express = true, 'Standard' if is_express = false OR is_express IS NULL
- **total_shipments**: Count of shipments
- **total_order_value**: Sum of order values
- **avg_total_days**: Average fulfillment time
- **sla_compliance_rate**: Overall SLA compliance
- **severe_breach_pct**: Percentage with severe breaches
- **warehouse_delay_pct**: Percentage with warehouse delays
- **carrier_delay_pct**: Percentage with carrier delays
- **pct_of_carrier_volume**: This tier's shipments as % of carrier's total shipments
- **pct_of_total_volume**: This tier's shipments as % of all shipments
- **value_tier_distribution**: Concatenated string showing distribution, format: "Budget: X.X%, Standard: Y.Y%, Premium: Z.Z%" (percentages rounded to 1 decimal place, e.g., "Budget: 25.5%, Standard: 45.0%, Premium: 29.5%")

### Rounding Rules

- Round day metrics to 2 decimal places
- Round percentages to 1 decimal place
- Round monetary values to 2 decimal places
- Round scores to 1 decimal place

## Output: fulfillment_sla

Order by fulfillment_month, warehouse_name, shipping_method_name.

## Output: carrier_performance

Order by carrier_rank ASC.

## Output: warehouse_performance

Order by warehouse_rank ASC.

## Output: fulfillment_summary

Order by carrier_name, service_tier.

## Materialization

- Intermediate models: views
- `fulfillment_sla`: table
- `carrier_performance`: table
- `warehouse_performance`: table
- `fulfillment_summary`: table

## Verification

```bash
cd <dbt_project_dir>
dbt run --select +fulfillment_sla +carrier_performance +warehouse_performance +fulfillment_summary
```

## Guidelines

- Use `DATEDIFF('day', start, end)` for date differences (works on both backends)
- Use `CAST(... AS DOUBLE)` for division to avoid integer division issues
- Use integer 1/0 instead of boolean true/false for cross-database compatibility
