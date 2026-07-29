FROM dbt-bench-base

# Copy the buggy model (to be fixed by agent)
COPY rpt_carrier_performance.sql /app/dbt_models_duckdb/models/marts/sales/rpt_carrier_performance.sql
COPY rpt_carrier_performance.sql /app/dbt_models_snowflake/models/marts/sales/rpt_carrier_performance.sql
