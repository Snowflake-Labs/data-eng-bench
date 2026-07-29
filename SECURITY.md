# Security Policy

`dbt-bench` is a benchmark dataset and evaluation harness, not a production
service. It contains no Snowflake production code, credentials, or customer data.

## Reporting a Vulnerability

If you discover a security issue in this repository — for example an unsafe
pattern in a task environment, the base Docker image, or the leaderboard
tooling — please report it **privately** rather than opening a public issue:

- Use GitHub's **"Report a vulnerability"** private advisory feature on this repo, or
- Email **security@snowflake.com**.

Please include a description, reproduction steps, and the affected path. We will
acknowledge receipt and work with you on a resolution.

## Credentials

Running the Snowflake-backed tasks requires you to supply **your own** Snowflake
credentials via your local `~/.snowflake/connections.toml` (or environment
variables). Never commit credentials to task directories, configs, or
leaderboard submissions.
