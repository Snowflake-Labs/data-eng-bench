# Advanced Multi-Touch Attribution with Hybrid Decay Model

Build a dbt model that implements a sophisticated multi-touch attribution system combining time-decay and position-based weighting with channel hierarchy rules and session quality filtering.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- dbt project: `/app/dbt_transforms`

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
- dbt project: `/app/dbt_models_snowflake`

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## dbt Profile Setup

You must configure dbt to connect to the database:
- Profile name: `retail_dw_master`
- Set `DBT_PROFILES_DIR` to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Data

Data is available via pre-existing staging models in the dbt project:
- `stg_digital__web_sessions` - web sessions with referrer info. Explore the table to understand available columns including session identifiers, visitor/customer IDs, channel info, timestamps, page metrics, referrer and UTM parameters, device details, and conversion flags.
- `stg_analytics__fact_sales` - sales/conversion events. Explore the table to understand available columns including sales keys, date/time keys, order details, quantities, and financial amounts.

## Project Setup

A dbt project already exists with the following configurations:

- DuckDB project: `/app/dbt_transforms`
- Snowflake project: `/app/dbt_models_snowflake`

All the required staging models are already implemented and available for use. Set up `profiles.yml` for the appropriate backend.

**Note**: Staging layer models (`stg_digital__web_sessions`, `stg_analytics__fact_sales`) are already available in the dbt project. Do not create staging layer models.

## Required Models

**Marts** (`models/marts/`):
- `attribution_report.sql` - The final output containing channel performance. This model should be materialized in the `main` schema.
  - **Note**: The default target schema is `main`. Do not explicitly configure `schema='main'` in the model, as it may cause dbt to generate a schema name like `main_main`. Ensure the model is materialized as a table.

## Output Requirements

**attribution_report** must contain:
- `channel`: The marketing channel (derived from referrer using hierarchical rules).
- `total_conversions`: Sum of fractional conversion credit.
- `total_revenue`: Sum of fractional revenue credit.

## Business Rules

You must implement all the following logic precisely. The attribution model uses a **Hybrid Decay** approach combining time-decay with position-based weighting.

### 1. Channel Classification (Hierarchical Priority)

Determine the `channel` for each session using the following **priority-ordered** rules. Apply rules in order and stop at the first match:

1. **Paid Search**: If `utm_medium` equals 'cpc' OR 'ppc' (case-insensitive), channel is 'Paid Search'.
2. **Paid Social**: If `utm_medium` equals 'paid_social' OR (`referrer` contains 'facebook' AND `utm_source` is not null and not empty), channel is 'Paid Social'.
3. **Organic Search**: If `referrer` contains 'google' OR 'bing' OR 'yahoo' (case-insensitive), channel is 'Organic Search'.
4. **Organic Social**: If `referrer` contains 'facebook' OR 'twitter' OR 'linkedin' OR 'instagram' (case-insensitive), channel is 'Organic Social'.
5. **Email**: If `utm_medium` equals 'email' (case-insensitive) OR `referrer` contains 'mail' (case-insensitive), channel is 'Email'.
6. **Direct**: If `referrer` is null OR empty string, channel is 'Direct'.
7. **Referral**: All other cases.

### 2. Session Quality Filtering

Before attribution, filter out low-quality sessions:
- **Exclude** sessions where `duration_seconds` < 5 (bounce sessions).
- **Exclude** sessions where `page_views` < 2 (single-page sessions).
- **Exclude** sessions from bot traffic: sessions where `device_type` equals 'bot' (case-insensitive).

Only sessions passing all quality filters are eligible for attribution.

### 3. Attribution Window

Link conversions to sessions:
- A conversion is identified by matching `order_id` from `stg_digital__web_sessions` (where `is_converted` is true) to `stg_analytics__fact_sales`.
- The conversion timestamp is the `session_start` of the converting session.
- Join sessions to conversions using `customer_id`.
- A conversion is attributed to all **quality-filtered** sessions for that customer that occurred **strictly before** the conversion timestamp.
- Use a **14-day lookback window** from the conversion timestamp.
- **Minimum Touch Requirement**: Conversions must have at least 2 eligible sessions to be attributed. If a conversion has only 1 eligible session, that session receives 100% credit (no minimum touch penalty applied).

### 4. Hybrid Decay Model

The attribution uses a combination of time-decay and position-based weighting:

#### Step 4a: Position-Based Weight
For each conversion, rank sessions by `session_start` (earliest = position 1):
- **First Touch Position Weight**: The first session (position 1) gets a position multiplier of **1.5**.
- **Last Touch Position Weight**: The last session (highest position) gets a position multiplier of **1.3**.
- **Middle Touches**: All other sessions get a position multiplier of **1.0**.
- If there are only 2 sessions, the first gets 1.5 and the second (also last) gets 1.3.
- If there is only 1 session, it gets position multiplier 1.0.

#### Step 4b: Time-Decay Weight
For a session occurring t days before the conversion:
- Time Weight = exp(-t/7)
- where t is the floating-point difference in days between session start and conversion time.

**Important**: Use natural exponential decay (exp(-t/7)), not binary decay.

#### Step 4c: Combined Weight
- Raw Weight = Position Multiplier x Time Weight

#### Step 4d: Normalization
Normalize weights per conversion so they sum to 1:
- Credit = Raw Weight(session) / Sum(Raw Weight for all eligible sessions)
- Attributed Revenue = Credit x Conversion Revenue

### 5. Channel Interaction Bonus

Apply a **cross-channel bonus** to conversions that have sessions from 3 or more distinct channels:
- If a conversion path includes >= 3 distinct channels, multiply the total conversion revenue by **1.1** before distributing credit.
- This bonus is applied to the revenue only, not to the conversion count.

### 6. Aggregation

- Group by `channel`.
- Sum credits to get `total_conversions`.
- Sum attributed revenue to get `total_revenue`.
- Round results to **2 decimal places**.
- **Order** the final output by `channel` alphabetically (ascending).

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible).
- Use Jinja conditionals (`{% if target.type == 'duckdb' %}...{% else %}...{% endif %}`) for any syntax that differs between backends (e.g., `date_diff` vs `DATEDIFF`, boolean comparisons).
- Handle boolean columns carefully -- Snowflake may store booleans as VARCHAR. Use `UPPER(CAST(col AS VARCHAR)) IN ('1', 'TRUE', 'T', 'Y', 'YES')` for Snowflake boolean checks.
- Use `interval '14 days'` syntax which works on both backends.
- Ensure idempotent execution (multiple runs produce the same results).
