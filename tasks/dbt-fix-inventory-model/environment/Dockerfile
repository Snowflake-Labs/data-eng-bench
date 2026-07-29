FROM dbt-bench-base

# Copy the buggy model (to be fixed by agent)
COPY data/rpt_product_inventory_metrics.sql /app/dbt_models_duckdb/models/marts/inventory/rpt_product_inventory_metrics.sql
COPY data/rpt_product_inventory_metrics.sql /app/dbt_models_snowflake/models/marts/inventory/rpt_product_inventory_metrics.sql
