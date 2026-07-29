# Customer Tier Migration Analysis

Build a tier migration analytics system with cohort tracking, velocity metrics, revenue impact, and retention risk scoring.

## Environment

- **DuckDB database**: `/app/database/retail.duckdb`
- **DuckDB dbt project**: `/app/dbt_models_duckdb`
- **Snowflake dbt project**: `/app/dbt_models_snowflake`
- **Target schema**: `tier_analytics` (appears as `main_tier_analytics`)

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

## Source Data

Use these sources:
- `CUSTOMER_TIER_HISTORY` - tier_history_id, customer_id, previous_tier_id, new_tier_id, change_reason, effective_date, points_at_change, spend_at_change
- `CUSTOMER_TIERS` - tier_id, tier_name, min_spend_required
- `ORDERS` - customer_id, ordered_at, grand_total

Tier levels: Higher MIN_SPEND_REQUIRED = higher tier level.

---

## Model 1: `tier_migration_matrix`

**Location**: `models/marts/tier/tier_migration_matrix.sql`

Shows customer movements between tiers. Order by customer_count DESC, from_tier ASC, to_tier ASC.

| Column | Description |
|--------|-------------|
| from_tier | Source tier name ('New' for NULL previous_tier_id) |
| to_tier | Destination tier name |
| customer_count | Number of customers who made this transition |
| avg_days_in_source | Average days between consecutive tier changes for this transition |
| avg_spend_change | Average difference in spend_at_change between consecutive records |
| avg_points_change | Average difference in points_at_change between consecutive records |
| migration_rate | Percentage of all transitions (should sum to 100%) |

---

## Model 2: `cohort_tier_progression`

**Location**: `models/marts/tier/cohort_tier_progression.sql`

Tracks cohorts through tier progression over time. Order by cohort_month, tier_name.

| Column | Description |
|--------|-------------|
| cohort_month | YYYY-MM of customer's first tier record |
| cohort_size | Initial number of customers in cohort |
| tier_name | Tier being tracked |
| count_at_30d | Customers in this tier at 30 days after first record |
| count_at_60d | Customers in this tier at 60 days |
| count_at_90d | Customers in this tier at 90 days |
| count_at_180d | Customers in this tier at 180 days |
| upgrade_rate_90d | % who moved to higher tier within 90 days |
| downgrade_rate_90d | % who moved to lower tier within 90 days |
| retention_rate_90d | % who stayed at same tier level within 90 days |

---

## Model 3: `tier_velocity_metrics`

**Location**: `models/marts/tier/tier_velocity_metrics.sql`

Speed of tier movement per customer. Order by total_tier_changes DESC, customer_id ASC.

| Column | Description |
|--------|-------------|
| customer_id | Customer identifier |
| total_tier_changes | Number of tier change records |
| first_change_date | Date of first tier record |
| last_change_date | Date of most recent tier record |
| tier_changes_per_year | Annualized rate (365 * changes / days_span), or changes if same day |
| avg_days_between_changes | Average days between consecutive changes |
| net_tier_movement | Sum of tier level changes (positive = net upgrade) |
| is_fast_mover | TRUE if total_tier_changes > 2 |
| is_churning | TRUE if net_tier_movement < 0 |
| movement_consistency | Standard deviation of days between changes (0 if not calculable) |

---

## Model 4: `tier_migration_revenue_impact`

**Location**: `models/marts/tier/tier_migration_revenue_impact.sql`

Revenue impact around tier changes. Order by total_revenue_impact DESC.

| Column | Description |
|--------|-------------|
| from_tier | Source tier name ('New' for NULL previous_tier_id) |
| to_tier | Destination tier name |
| transition_count | Number of transitions |
| avg_revenue_before | Average revenue in 30 days before tier change |
| avg_revenue_after | Average revenue in 30 days after tier change |
| avg_revenue_lift_pct | Percentage change: 100 * (after - before) / before (NULL if before = 0) |
| total_revenue_impact | Sum of (revenue_after - revenue_before) across all transitions |

---

## Model 5: `tier_retention_risk`

**Location**: `models/marts/tier/tier_retention_risk.sql`

Churn risk scoring per customer. Order by risk_score DESC, customer_id ASC.

| Column | Description |
|--------|-------------|
| customer_id | Customer identifier |
| current_tier | Current tier name (from most recent record) |
| days_since_last_change | Days from last tier change to the most recent effective_date in the tier history data |
| recent_downgrade | TRUE if downgraded within 90 days (relative to the most recent effective_date) |
| spend_percentile | Customer's spend percentile (0-100) |
| points_trend | 'Declining' if points decreased, else 'Stable/Growing' |
| risk_score | Sum of risk factors (0-100) |
| risk_category | 'Low' (0-25), 'Medium' (26-50), 'High' (51-75), 'Critical' (76-100) |

**Risk Factors** (each 0-25 points):
- days_since_last_change > 365: +25
- recent_downgrade = TRUE: +25
- spend_percentile < 25: +25
- points_trend = 'Declining': +25

**Important**: Use `MAX(effective_date)` from the tier history data as the reference date for all time-relative calculations (days_since_last_change, recent_downgrade window). Do NOT use `CURRENT_DATE`.

---

## Edge Cases

- NULL previous_tier_id: Treat as 'New' tier
- NULL spend_at_change or points_at_change: Treat as 0
- Customers with single tier record: Include in velocity (changes=1) but no avg_days
- No orders within 30-day window: revenue = 0
- All monetary values rounded to 2 decimal places

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
