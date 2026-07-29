FROM dbt-bench-base

# Copy the buggy model to BOTH backend project dirs
COPY rpt_category_performance.sql /app/dbt_models_duckdb/models/marts/product/rpt_category_performance.sql
COPY rpt_category_performance.sql /app/dbt_models_snowflake/models/marts/product/rpt_category_performance.sql
