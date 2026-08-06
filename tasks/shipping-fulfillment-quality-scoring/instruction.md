# Shipping & Fulfillment Quality Scoring

Build dbt models for shipping and fulfillment quality analysis with delivery scoring and carrier performance metrics.

## Your Task

Add dbt models to the existing project that create shipping quality metrics and carrier performance scorecards.

- DuckDB: `/app/dbt_models_duckdb/models/`
- Snowflake: `/app/dbt_models_snowflake/models/`

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

## Source

Use existing staging models in models/staging/orders/:
- stg_orders__shipments
- stg_orders__shipment_tracking
- stg_orders__shipment_packages
- stg_orders__shipment_lines
- stg_orders__orders
- stg_orders__returns

And reference data from REFERENCE schema:
- REFERENCE.CARRIERS
- REFERENCE.SHIPPING_METHODS

Explore these tables to understand available columns.

## Required Models

### Intermediate Layer (`models/intermediate/fulfillment/`)

#### int_shipment_tracking_metrics

One row per shipment_id from stg_orders__shipments and stg_orders__shipment_tracking.

| Column | Description |
|--------|-------------|
| shipment_id | Group key |
| tracking_events_count | Total number of tracking events for this shipment |
| first_tracking_at | Earliest tracked_at timestamp |
| last_tracking_at | Latest tracked_at timestamp |
| has_exception | TRUE if any tracking event has status = 'EXCEPTION' |
| tracking_duration_hours | Hours between first and last tracking event, default 0 |
| avg_hours_between_updates | Average hours between consecutive tracking updates, default 0, rounded to 2 decimals |
| distinct_locations_count | Count of distinct location values in tracking |
| reached_out_for_delivery | TRUE if any tracking status = 'OUT_FOR_DELIVERY' |

#### int_shipment_delivery_metrics

One row per shipment_id from stg_orders__shipments joined with REFERENCE.SHIPPING_METHODS.

| Column | Description |
|--------|-------------|
| shipment_id | Group key |
| order_id | From stg_orders__shipments |
| carrier_id | From stg_orders__shipments |
| shipping_method_id | From stg_orders__shipments |
| shipped_at | From stg_orders__shipments |
| delivered_at | From stg_orders__shipments, NULL if not delivered |
| shipping_cost | From stg_orders__shipments |
| weight | From stg_orders__shipments |
| status | From stg_orders__shipments |
| is_delivered | TRUE if status = 'DELIVERED' |
| delivery_days | Days between shipped_at and delivered_at, NULL if not delivered |
| estimated_days_min | From REFERENCE.SHIPPING_METHODS |
| estimated_days_max | From REFERENCE.SHIPPING_METHODS |
| is_express | From REFERENCE.SHIPPING_METHODS |
| sla_target_days | estimated_days_max from shipping method |
| is_on_time | TRUE if delivery_days <= sla_target_days, NULL if not delivered |
| days_early_or_late | sla_target_days minus delivery_days (positive = early, negative = late), NULL if not delivered |

#### int_shipment_package_metrics

One row per shipment_id from stg_orders__shipments, stg_orders__shipment_packages, and stg_orders__shipment_lines.

| Column | Description |
|--------|-------------|
| shipment_id | Group key |
| package_count | Count of packages in this shipment |
| total_weight | Sum of package weights, default 0 |
| total_volume_cubic | Sum of (length * width * height) for all packages, default 0 |
| avg_package_weight | Average weight per package, default 0, rounded to 2 decimals |
| items_shipped | Sum of quantity_shipped from shipment lines |
| line_count | Count of distinct shipment lines |

### Marts Layer (`models/marts/fulfillment/`)

#### shipment_quality_scores

One row per shipment_id joining int_shipment_delivery_metrics, int_shipment_tracking_metrics, int_shipment_package_metrics, and REFERENCE.CARRIERS.

| Column | Description |
|--------|-------------|
| shipment_id | Primary key |
| shipment_number | From stg_orders__shipments |
| order_id | From int_shipment_delivery_metrics |
| carrier_id | From int_shipment_delivery_metrics |
| carrier_name | From REFERENCE.CARRIERS |
| carrier_type | From REFERENCE.CARRIERS (PARCEL, FREIGHT, COURIER, PICKUP) |
| shipping_method_id | From int_shipment_delivery_metrics |
| is_express | From int_shipment_delivery_metrics |
| shipped_at | From int_shipment_delivery_metrics |
| shipped_date | Date of shipped_at |
| delivered_at | From int_shipment_delivery_metrics |
| status | From int_shipment_delivery_metrics |
| is_delivered | From int_shipment_delivery_metrics |
| delivery_days | From int_shipment_delivery_metrics |
| sla_target_days | From int_shipment_delivery_metrics |
| is_on_time | From int_shipment_delivery_metrics |
| days_early_or_late | From int_shipment_delivery_metrics |
| shipping_cost | From int_shipment_delivery_metrics |
| weight | From int_shipment_delivery_metrics |
| package_count | From int_shipment_package_metrics |
| items_shipped | From int_shipment_package_metrics |
| tracking_events_count | From int_shipment_tracking_metrics |
| has_exception | From int_shipment_tracking_metrics |
| avg_hours_between_updates | From int_shipment_tracking_metrics |
| delivery_score | Delivery performance score (see below) |
| tracking_score | Tracking quality score (see below) |
| cost_efficiency_score | Cost efficiency score (see below) |
| overall_quality_score | Weighted composite score (see below) |
| quality_tier | 'EXCELLENT' if overall >= 85, 'GOOD' if >= 70, 'FAIR' if >= 50, 'POOR' otherwise |

#### carrier_performance_scorecard

One row per carrier_id aggregating shipment_quality_scores from shipments on or after 2025-10-04.

| Column | Description |
|--------|-------------|
| carrier_id | Group key |
| carrier_name | From REFERENCE.CARRIERS |
| carrier_type | From REFERENCE.CARRIERS |
| total_shipments | Count of shipments |
| delivered_shipments | Count of shipments where is_delivered = TRUE |
| delivery_rate | delivered_shipments divided by total_shipments, rounded to 4 decimals |
| on_time_shipments | Count of shipments where is_on_time = TRUE |
| on_time_delivery_rate | on_time_shipments divided by delivered_shipments, default 0 if no deliveries, rounded to 4 decimals |
| avg_delivery_days | Average delivery_days for delivered shipments, default 0, rounded to 2 decimals |
| avg_days_early_or_late | Average days_early_or_late for delivered shipments, default 0, rounded to 2 decimals |
| exception_shipments | Count of shipments where has_exception = TRUE |
| exception_rate | exception_shipments divided by total_shipments, rounded to 4 decimals |
| total_shipping_cost | Sum of shipping_cost |
| avg_shipping_cost | Average shipping_cost, rounded to 2 decimals |
| total_weight_shipped | Sum of weight |
| avg_cost_per_lb | total_shipping_cost divided by total_weight_shipped, default 0, rounded to 4 decimals |
| avg_delivery_score | Average delivery_score, rounded to 2 decimals |
| avg_tracking_score | Average tracking_score, rounded to 2 decimals |
| avg_overall_quality_score | Average overall_quality_score, rounded to 2 decimals |
| performance_tier | 'PREMIUM' if avg_overall_quality_score >= 85, 'RELIABLE' if >= 70, 'STANDARD' if >= 50, 'UNDERPERFORMING' otherwise |
| rank_by_quality | Rank by avg_overall_quality_score descending (1 = best) |
| rank_by_volume | Rank by total_shipments descending (1 = highest volume) |

## Delivery Score

Score based on delivery performance (0-100):
- Delivered on time (0 or more days early): 100
- Delivered 1 day late: 80
- Delivered 2 days late: 60
- Delivered 3 days late: 40
- Delivered 4+ days late: 20
- Not delivered but in transit (status = 'IN_TRANSIT' or 'SHIPPED'): 50
- Pending (status = 'PENDING'): 30
- Cancelled (status = 'CANCELLED'): 0
- Otherwise: 10

Default 0 for NULL shipped_at.

## Tracking Score

Score based on tracking quality (0-100):
- 6+ tracking events: 100
- 5 tracking events: 90
- 4 tracking events: 75
- 3 tracking events: 60
- 2 tracking events: 40
- 1 tracking event: 20
- 0 tracking events: 0

Add bonus: +10 if avg_hours_between_updates > 0 AND avg_hours_between_updates <= 12 (frequent updates; zero means no tracking data, not frequent updates)
Subtract penalty: -20 if has_exception = TRUE

Cap final score between 0 and 100.

## Cost Efficiency Score

Score based on cost per pound efficiency (0-100):
- cost_per_lb <= 2.0: 100
- cost_per_lb <= 3.0: 85
- cost_per_lb <= 4.0: 70
- cost_per_lb <= 5.0: 55
- cost_per_lb <= 7.0: 40
- cost_per_lb <= 10.0: 25
- cost_per_lb > 10.0: 10

Where cost_per_lb = shipping_cost / NULLIF(weight, 0), default 50 if weight is 0 or NULL.

## Overall Quality Score

Weighted composite score:
- Delivery score: 50% weight
- Tracking score: 30% weight
- Cost efficiency score: 20% weight

Formula: (delivery_score * 0.5) + (tracking_score * 0.3) + (cost_efficiency_score * 0.2)

Round to 2 decimals.

## Requirements

### shipment_quality_scores
- Only include shipments where shipped_at is on or after 2025-10-04
- One row per shipment_id
- No NULL values in shipment_id, carrier_id, shipped_at, delivery_score, tracking_score, cost_efficiency_score, overall_quality_score, quality_tier
- All scores range: 0-100
- quality_tier must be one of: 'EXCELLENT', 'GOOD', 'FAIR', 'POOR'
- Order by shipped_at descending

### carrier_performance_scorecard
- Only include shipments on or after 2025-10-04
- One row per carrier_id
- No NULL values in carrier_id, carrier_name, total_shipments, delivery_rate, on_time_delivery_rate, performance_tier
- All rates range: 0.0-1.0
- performance_tier must be one of: 'PREMIUM', 'RELIABLE', 'STANDARD', 'UNDERPERFORMING'
- Order by avg_overall_quality_score descending, then by carrier_name

### int_shipment_tracking_metrics
- One row per shipment_id
- No NULL values in shipment_id, tracking_events_count
- Include shipments even if they have no tracking events (with tracking_events_count = 0)

### int_shipment_delivery_metrics
- One row per shipment_id
- No NULL values in shipment_id, order_id, carrier_id, status
- Join with shipping methods to get SLA targets

### int_shipment_package_metrics
- One row per shipment_id
- No NULL values in shipment_id, package_count, items_shipped
- Include shipments even if they have no packages (with package_count = 0)

## Guidelines

- Use DATEDIFF for date difference calculations
- Use CAST AS DOUBLE for division precision when needed
- Avoid DuckDB-specific syntax like `::numeric` casts; use standard CAST instead
