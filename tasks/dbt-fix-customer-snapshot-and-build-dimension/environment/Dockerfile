FROM dbt-bench-base

# Copy the buggy snapshot model to BOTH backend project dirs
COPY data/customer_snapshot.sql /app/dbt_models_duckdb/snapshots/customer_snapshot.sql
COPY data/customer_snapshot.sql /app/dbt_models_snowflake/snapshots/customer_snapshot.sql
