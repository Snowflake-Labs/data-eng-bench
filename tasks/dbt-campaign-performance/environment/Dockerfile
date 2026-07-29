FROM dbt-bench-base

COPY data/create_marketing_tables.sql /app/setup/create_marketing_tables.sql
COPY data/stg_marketing__campaigns.sql /app/dbt_models_duckdb/models/staging/marketing/stg_marketing__campaigns.sql
COPY data/stg_marketing__campaigns.sql /app/dbt_models_snowflake/models/staging/marketing/stg_marketing__campaigns.sql
COPY data/stg_marketing__email_events.sql /app/dbt_models_duckdb/models/staging/marketing/stg_marketing__email_events.sql
COPY data/stg_marketing__email_events.sql /app/dbt_models_snowflake/models/staging/marketing/stg_marketing__email_events.sql
COPY data/marketing_sources.yml /app/dbt_models_duckdb/models/staging/marketing/marketing_sources.yml
COPY data/marketing_sources.yml /app/dbt_models_snowflake/models/staging/marketing/marketing_sources.yml

# Run the SQL script to create and populate marketing tables in DuckDB
RUN mkdir -p /app/dbt_models_duckdb/models/staging/marketing && \
    python3 -c "import duckdb; conn = duckdb.connect('/app/database/retail.duckdb'); conn.execute(open('/app/setup/create_marketing_tables.sql').read()); conn.close()"
