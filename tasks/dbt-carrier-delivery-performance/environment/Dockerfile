FROM ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0

# Copy the buggy model (to be fixed by agent)
COPY rpt_carrier_performance.sql /app/dbt_models_duckdb/models/marts/sales/rpt_carrier_performance.sql
COPY rpt_carrier_performance.sql /app/dbt_models_snowflake/models/marts/sales/rpt_carrier_performance.sql
