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

Works with GitHub Actions and GitLab CI.

**Status:** in development. Not ready for use yet.
