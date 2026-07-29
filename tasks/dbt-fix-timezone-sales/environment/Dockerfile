FROM dbt-bench-base

# Copy buggy model to BOTH backend project dirs
COPY int_sales__orders_enriched.sql /app/dbt_models_duckdb/models/intermediate/sales/int_sales__orders_enriched.sql
COPY int_sales__orders_enriched.sql /app/dbt_models_snowflake/models/intermediate/sales/int_sales__orders_enriched.sql
