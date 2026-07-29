FROM dbt-bench-base

# Copy the buggy model (to be fixed by agent)
COPY data/rpt_customer_metrics.sql /app/dbt_models_duckdb/models/marts/customer/rpt_customer_metrics.sql
COPY data/rpt_customer_metrics.sql /app/dbt_models_snowflake/models/marts/customer/rpt_customer_metrics.sql
