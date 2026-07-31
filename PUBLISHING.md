# Publishing dbt-bench (maintainer runbook)

Exact steps to take this repo from the staging checkout to a live, public
Harbor dataset + leaderboard under the `Snowflake-Labs` org. Run top-to-bottom.

> **Blocker up front — SSO.** Pushing to `github.com/Snowflake-Labs` requires an
> SSO-authorized token. A bare PAT is rejected until authorized for the
> `Snowflake-Labs` org (`gh auth login` with SSO, or authorize the PAT at
> `https://github.com/settings/tokens` → "Configure SSO"). Do this before
> Step 2. Publishing to the Harbor Hub (Steps 4–6) is independent of GitHub SSO
> and uses a `HARBOR_API_KEY`.

## 1. Git LFS for the large database

`base-image/database/retail.duckdb` is ~489 MB. Keep it in Git LFS (already
configured via `.gitattributes`):

```bash
git lfs install
git lfs track "base-image/database/*.duckdb"     # already in .gitattributes
git add .gitattributes base-image/database/retail.duckdb
git commit -m "Track retail.duckdb via Git LFS"
git lfs ls-files                                  # confirm it's an LFS object
```

GitHub free LFS is 1 GB storage / 1 GB-month bandwidth. dbt-bench's single
~489 MB object fits, but every `git lfs pull` by a runner/user burns bandwidth.
See "retail.duckdb hosting decision" below.

## 2. Create the GitHub repo and push (needs SSO)

```bash
gh repo create Snowflake-Labs/dbt-bench --public --source . --remote origin --push
# or, if the repo exists:
git remote add origin git@github.com:Snowflake-Labs/dbt-bench.git
git push -u origin main            # LFS objects upload automatically
```

If the push is rejected with an SSO error, authorize the token (see blocker
above) and retry.

## 3. Build and push the base image

The task `environment/Dockerfile`s do `FROM dbt-bench-base`. For a public
dataset, publish the base image to a public registry and point the task
Dockerfiles at the pinned tag (or keep `dbt-bench-base` as a documented local
build — see the hosting decision).

```bash
git lfs pull --include="base-image/database/*"    # ensure real DB, not pointer
docker build base-image/ -t ghcr.io/snowflake-labs/dbt-bench-base:1.0.0
docker push ghcr.io/snowflake-labs/dbt-bench-base:1.0.0
# make the GHCR package public in the org's package settings
```

If you repoint the task Dockerfiles at the GHCR tag, do it repo-wide:

```bash
# tasks/*/environment/Dockerfile: FROM dbt-bench-base
#                              ->  FROM ghcr.io/snowflake-labs/dbt-bench-base:1.0.0
grep -rl '^FROM dbt-bench-base' tasks | xargs sed -i \
  's#^FROM dbt-bench-base#FROM ghcr.io/snowflake-labs/dbt-bench-base:1.0.0#'
```

## 4. Authenticate to Harbor

```bash
uv tool install harbor
harbor auth login                                  # GitHub OAuth in browser
jq -r .api_key ~/.harbor/credentials.json          # the sk-harbor-... key, for CI secrets
```

## 5. Publish the dataset

```bash
# (Optional) regenerate/refresh the manifest from the tasks/ directory:
harbor dataset init "Snowflake-Labs/dbt-bench" \
  --description "Agentic dbt data-engineering benchmark (DuckDB + Snowflake)" \
  --author "Snowflake <opensource@snowflake.com>"

harbor publish Snowflake-Labs/dbt-bench --public -t v1.0
```

`harbor publish` prints the canonical dataset digest (`sha256:...`). **Copy it
into `leaderboard/src/leaderboard/core/hub.py`** (`DATASET_REF`) — replacing the
`REPLACE_WITH_PUBLISHED_DATASET_DIGEST` placeholder — commit, and push. CI uses
that digest to prove every submitted trial ran the official, unmodified tasks.

## 6. Create the leaderboard on the Hub

```bash
harbor hub leaderboard create --config leaderboard/leaderboard.yaml
```

Then complete the one-time repo wiring from
[leaderboard/SETUP.md](leaderboard/SETUP.md):

- set repo secrets: `HARBOR_API_KEY`, `ANTHROPIC_API_KEY`, `MODAL_TOKEN_ID`,
  `MODAL_TOKEN_SECRET`;
- `gh label create lb-submission --repo Snowflake-Labs/dbt-bench --color 0E8A16`;
- enable "Allow GitHub Actions to create and approve pull requests" (org-level —
  needs org admin, another `Snowflake-Labs` gate).

## retail.duckdb hosting decision

**Chosen: baked into the base image; kept in the repo via Git LFS as the
source of record.** Rationale:

- Task containers must have the DB locally for `DB_TYPE=duckdb`; baking it into
  `dbt-bench-base` is the simplest correct path (no per-trial download, works
  offline in the sandbox).
- Keeping it in-repo via LFS gives a single source of truth and lets
  `migrate_duckdb.py` users grab it without pulling the whole image.
- **Watch item:** GitHub LFS bandwidth. If clones/CI pulls exceed the free
  quota, move the canonical file to a public object store (e.g. an S3/GCS
  bucket or a GHCR OCI artifact), have the Dockerfile `curl` it at build time,
  and drop it from LFS. The README's "extract from the image" instructions stay
  valid either way.

## Go-live checklist

- [ ] SSO-authorized token for `Snowflake-Labs`
- [ ] `git lfs pull` shows real `retail.duckdb` (not a pointer)
- [ ] `docker build base-image/` succeeds locally
- [ ] repo pushed to `github.com/Snowflake-Labs/dbt-bench`
- [ ] base image pushed to GHCR and made public
- [ ] `harbor publish` done; `DATASET_REF` digest pasted into `hub.py` and pushed
- [ ] leaderboard created; secrets, label, and org Actions setting configured
- [ ] a smoke submission PR turns the CI green end-to-end
