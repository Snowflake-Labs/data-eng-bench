FROM ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0

# Copy the buggy model (to be fixed by agent)
COPY data/rpt_customer_metrics.sql /app/dbt_models_duckdb/models/marts/customer/rpt_customer_metrics.sql
COPY data/rpt_customer_metrics.sql /app/dbt_models_snowflake/models/marts/customer/rpt_customer_metrics.sql
