# data-eng-bench base image (public build).
#
# Builds the shared runtime that every data-eng-bench task extends via
# `FROM ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0`. Fully public sources only — Docker Hub for the base
# image, public PyPI for Python packages, NodeSource for Node.js. No private
# registries or artifact stores are referenced.
#
# Build (from this directory):
#   docker build -t ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0 .
#
# Publish (maintainers, see ../PUBLISHING.md):
#   docker build -t ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0 .
#   docker push  ghcr.io/snowflake-labs/data-eng-bench-base:1.0.0
FROM python:3.12-slim

# dbt adapters, DuckDB, and the test toolchain. Versions are pinned to match
# the set the benchmark was authored and verified against.
RUN pip install --no-cache-dir \
    dbt-duckdb==1.10.0 \
    "dbt-core>=1.8.0,<1.11" \
    duckdb==1.2.2 \
    pytest==8.4.1 \
    pytest-json-ctrf==0.3.5 \
    numpy==1.26.4 \
    pandas==2.2.2 \
    dbt-snowflake==1.10.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 — required by CLI coding agents that run inside the container
# (e.g. Claude Code). Agents that need their own CLI install it in agent setup.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Copy DuckDB dbt project (staging + intermediate + mart models, seeds, macros).
COPY dbt_models_duckdb /app/dbt_models_duckdb

# Copy Snowflake dbt project.
COPY dbt_models_snowflake /app/dbt_models_snowflake

# Bake in the full DuckDB database with all source tables. Tracked via Git LFS
# in the repo; `git lfs pull` must run before building (see ../PUBLISHING.md).
# Required for DB_TYPE=duckdb runs (the hermetic, zero-account default).
COPY database/retail.duckdb /app/database/retail.duckdb

# Data-quality fix: RAW_SAP.VBAP.product_id is NULL for all rows in the source
# data; populate it from ORDERS.ORDER_LINES (joined on order_line_id). Without
# this fix, int_sales__order_lines.product_id is always NULL and some verifiers
# silently pass on a zero-row check regardless of what the agent builds.
COPY fix_data.py /tmp/fix_data.py
RUN python3 /tmp/fix_data.py

# Materialize the dbt staging + intermediate layers in DuckDB so agents can
# reference stg_* and int_* models out of the box. Without this, only the raw
# source tables exist.
RUN cd /app/dbt_models_duckdb && \
    dbt deps --profiles-dir . && \
    dbt run --profiles-dir . --target dev

# Container lifecycle scripts.
COPY entrypoint.sh /entrypoint.sh
COPY cleanup_snowflake.py /cleanup_snowflake.py
RUN chmod +x /entrypoint.sh /cleanup_snowflake.py

# Snowflake per-task clone. Harbor overrides the image ENTRYPOINT with its own
# keepalive, so the clone can't live in entrypoint.sh; each task runs this via
# its Harbor healthcheck (`[environment.healthcheck]`) before the agent starts.
COPY snowflake_clone.py /snowflake_clone.py
RUN chmod +x /snowflake_clone.py

# Make the clone's SNOWFLAKE_DATABASE (written to /tmp/snowflake_env.sh by the
# healthcheck) visible to every shell the agent/verifier spawn: BASH_ENV covers
# non-interactive `bash -c` (how tool shells run), bash.bashrc covers
# interactive shells. No-op until the healthcheck creates the file.
RUN printf '%s\n' '[ -f /tmp/snowflake_env.sh ] && . /tmp/snowflake_env.sh' > /etc/dbt_bench_env.sh
ENV BASH_ENV=/etc/dbt_bench_env.sh
RUN printf '\n%s\n' '[ -f /tmp/snowflake_env.sh ] && . /tmp/snowflake_env.sh' >> /etc/bash.bashrc

COPY wait-for-init.sh /etc/profile.d/wait-for-init.sh
RUN chmod +x /etc/profile.d/wait-for-init.sh

# Default backend is DuckDB (hermetic). Set DB_TYPE=snowflake to run against a
# Snowflake account (see ../README.md "Quickstart (Snowflake)").
ENV DB_TYPE=duckdb
ENV DUCKDB_PATH=/app/database/retail.duckdb
ENV DBT_PROJECT_DIR_DUCKDB=/app/dbt_models_duckdb
ENV DBT_PROJECT_DIR_SNOWFLAKE=/app/dbt_models_snowflake

# Snowflake connection env — left blank; populated per-run when DB_TYPE=snowflake.
ENV SNOWFLAKE_ACCOUNT=""
ENV SNOWFLAKE_USER=""
ENV SNOWFLAKE_PASSWORD=""
ENV SNOWFLAKE_PRIVATE_KEY=""
ENV SNOWFLAKE_PRIVATE_KEY_PASSPHRASE=""
ENV SNOWFLAKE_SOURCE_DATABASE=""
# Canonical output schema. Verifiers read `main.<model>`; a blank default makes
# entrypoint.sh fall back to PUBLIC, which silently materializes models into the
# wrong schema — so pin it to "main".
ENV SNOWFLAKE_SCHEMA="main"
ENV SNOWFLAKE_WAREHOUSE=""
ENV SNOWFLAKE_ROLE=""
ENV SNOWFLAKE_ADMIN_ROLE=""
ENV SNOWFLAKE_AGENT_ROLE_PREFIX=""

WORKDIR /app

ENTRYPOINT ["/entrypoint.sh"]
