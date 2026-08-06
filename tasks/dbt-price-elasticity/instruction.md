# Price Elasticity Analysis

The pricing team is preparing for a major price adjustment: "We're thinking of raising prices on 200 SKUs but we have no idea how customers will react. Which products are price-sensitive? We need elasticity coefficients before we make a costly mistake."

## Your Task

Create a dbt model `product_elasticity` in schema `elasticity_analytics` that calculates price elasticity of demand for each product.

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

## Environment

- **DuckDB project location**: Create a new standalone dbt project at `/app/dbt_project`
- **Snowflake project location**: Use the pre-built project at `/app/dbt_models_snowflake`
- **Schema**: `elasticity_analytics` (DuckDB) / `main` (Snowflake)

## dbt Profile Setup

You must configure dbt to connect to the database:
- Profile name: `retail_dw_master`
- Create a `profiles.yml` in the dbt project directory
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

## Source Data

Explore the database to find tables containing price history and order/sales data. You'll need to join data from the `PRODUCT` and `ORDERS` schemas to calculate price changes and corresponding quantity changes over time.

## Requirements

- Use midpoint formula: elasticity = (% change quantity) / (% change price)
- Aggregate to monthly periods for price and quantity
- Exclude months with zero sales or zero/negative prices
- Require at least 3 valid observations per product
- Cap elasticity between -10 and 10 to handle outliers

## Output Columns

| Column | Description |
|--------|-------------|
| product_id | Product identifier |
| elasticity_coefficient | Average elasticity (capped -10 to 10) |
| elasticity_type | elastic (abs > 1), inelastic (abs < 1), or unit_elastic (abs within 0.01 of 1) |
| num_observations | Number of valid period comparisons |
| avg_price | Average price across periods |
| avg_quantity | Average quantity across periods |

## Guidelines

- For date formatting, use `strftime()` on DuckDB and `TO_VARCHAR()` on Snowflake
- Install additional libraries as needed
