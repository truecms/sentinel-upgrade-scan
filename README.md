# Sentinel upgrade scan

Runs the Drupal [Upgrade Status](https://www.drupal.org/project/upgrade_status)
scan in your own CI pipeline and sends the result to
[Sentinel](https://sentinelconnector.io). Upgrade Status never needs to be on
production.

- Runs inside your own site image, beside a copy of your database.
- Adds Upgrade Status for that run only. Nothing is committed.
- Sends counts only: never project names, file paths, messages or database
  content.
- Does nothing unless `SENTINEL_UPGRADE_SCAN` is set.
- With no database it stops without failing your pipeline, and Sentinel shows
  why.

Works with GitHub Actions and GitLab CI. There is no Docker image: the scan
runs in the image you already build for your site.

## What you need

- The [Sentinel Connector](https://www.drupal.org/project/sentinel_connector)
  module, version **1.6.0 or later**, enabled on the site.
- An image of your site with PHP, Composer, Drush, `bash` and `curl`.
- A copy of your database the job can reach. Use a sanitised copy.
- The site's UUID and a scan key, from the site page in Sentinel. The key is
  shown once. Store it as a secret.

The scan key can only send scan results for its own site. It cannot read
anything, and it cannot change the site's modules in Sentinel.

## GitHub Actions

```yaml
name: Sentinel upgrade scan
on:
  workflow_dispatch:
  schedule:
    - cron: '0 3 * * 1'
jobs:
  scan:
    runs-on: ubuntu-latest
    # Your own site image, and a sanitised copy of your database.
    container: ghcr.io/your-org/your-site:latest
    services:
      database:
        image: ghcr.io/your-org/your-site-db:latest
    env:
      SENTINEL_UPGRADE_SCAN: '1'
    steps:
      - uses: actions/checkout@v5
      - uses: truecms/sentinel-upgrade-scan@v1.0.0
        with:
          site-uuid: 00000000-0000-0000-0000-000000000000
          scan-key: ${{ secrets.SENTINEL_SCAN_KEY }}
```

Inputs:

| Input | Required | Meaning |
|---|---|---|
| `site-uuid` | yes | The site's UUID in Sentinel. |
| `scan-key` | yes | The scan key, from a secret. |
| `api-url` | no | Sentinel API base URL. Empty: the connector's setting, else production. |
| `working-directory` | no | The Composer project root. Default: `.` |
| `drush` | no | The Drush command. Default: `vendor/bin/drush`, else `drush`. |

GitHub turns off scheduled workflows in public repositories after 60 days with
no activity. Sentinel marks the result out of date when that happens.

## GitLab CI

```yaml
include:
  - remote: https://raw.githubusercontent.com/truecms/sentinel-upgrade-scan/v1.0.0/gitlab/scan.yml

sentinel-upgrade-scan:
  # Your own site image, and a sanitised copy of your database.
  image: registry.example.com/your-site:latest
  services:
    - name: registry.example.com/your-site-db:latest
      alias: database
  # Runs from a pipeline schedule (add one under Build > Pipeline schedules,
  # for example every Monday: 0 3 * * 1) or a pipeline you start by hand.
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
    - if: $CI_PIPELINE_SOURCE == "web"
  variables:
    SENTINEL_UPGRADE_SCAN: '1'
    SENTINEL_SITE_UUID: 00000000-0000-0000-0000-000000000000
    # Set SENTINEL_SCAN_KEY as a masked CI/CD variable.
```

The template downloads `scan.sh` from the same release and checks its SHA-256
before it runs.

## Settings

The script reads these environment variables. The GitHub action sets them from
its inputs.

| Variable | Meaning |
|---|---|
| `SENTINEL_UPGRADE_SCAN` | Must be set, and not `0` or `false`, or nothing runs. |
| `SENTINEL_SITE_UUID` | The site's UUID in Sentinel. |
| `SENTINEL_SCAN_KEY` | The scan key. Never printed. |
| `SENTINEL_API_URL` | Optional API base URL, with no path. |
| `SENTINEL_PROJECT_DIR` | Optional Composer project root. |
| `SENTINEL_DRUSH` | Optional Drush command. |

If your `settings.php` sets the connector's Site UUID or API URL, the
connector uses those values for the result. Keep them the same as the values
above.

## What it does

1. `SENTINEL_UPGRADE_SCAN` is not set: it does nothing and exits 0.
2. Drupal has no working database: it tells Sentinel `no_database` and exits 0.
3. The connector is missing, disabled or older than 1.6.0: it tells Sentinel
   `connector_outdated` and fails.
4. Upgrade Status is missing: it adds it with Composer for this run, then
   enables it. If Composer cannot add it, it tells Sentinel `install_failed`
   and fails.
5. It runs `drush upgrade_status:analyze --all`. Exit code 3 means the scan
   found problems, which is a good scan. Any other failure tells Sentinel
   `scan_failed` and fails.
6. It runs `drush sentinel_connector:upgrade-status --scan-report`, which sends
   the counts. A custom project with no good scan from this run tells Sentinel
   `scan_failed`.
7. It puts `composer.json` and `composer.lock` back as they were.

If the scan route is closed on Sentinel, it logs one line and exits 0.

Network use: Composer sources, Drupal.org release data and the Sentinel API.

## Pin a release

Use a release tag you have reviewed, or a full commit SHA:

```yaml
- uses: truecms/sentinel-upgrade-scan@<full commit SHA>
```

## Development

```bash
shellcheck scan.sh scripts/pin-gitlab.sh tests/stubs/*
bats tests/scan.bats
```

To release: run `scripts/pin-gitlab.sh vX.Y.Z`, commit, then tag `vX.Y.Z`.

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).
