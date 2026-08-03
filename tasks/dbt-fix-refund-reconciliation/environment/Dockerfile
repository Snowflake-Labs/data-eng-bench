FROM ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0

# Copy the buggy model (to be fixed by agent)
COPY data/rpt_return_reconciliation.sql /app/dbt_models_duckdb/models/marts/sales/rpt_return_reconciliation.sql
COPY data/rpt_return_reconciliation.sql /app/dbt_models_snowflake/models/marts/sales/rpt_return_reconciliation.sql
