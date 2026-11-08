#!/usr/bin/env bats
# Tests for scan.sh with stand-in drush, composer and curl (tests/stubs).

KEY="sk_scan_$(printf 'a%.0s' {1..64})"
UUID='0f8fad5b-d9cb-469f-a165-70867728950e'

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJECT="$BATS_TEST_TMPDIR/site"
  mkdir -p "$PROJECT/web"
  echo '{"original": true}' > "$PROJECT/composer.json"
  echo '{"original": true}' > "$PROJECT/composer.lock"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  : > "$STUB_LOG"
  export PATH="$ROOT/tests/stubs:$PATH"
  export SENTINEL_UPGRADE_SCAN=1
  export SENTINEL_SITE_UUID="$UUID"
  export SENTINEL_SCAN_KEY="$KEY"
  export SENTINEL_API_URL='https://sentinel.example'
  export SENTINEL_PROJECT_DIR="$PROJECT"
  export SENTINEL_DRUSH="$ROOT/tests/stubs/drush"
  unset SENTINEL_CONNECTOR_API_BASE_URL
}

scan() { run bash "$ROOT/scan.sh"; }

@test 'does nothing without SENTINEL_UPGRADE_SCAN' {
  unset SENTINEL_UPGRADE_SCAN
  scan
  [ "$status" -eq 0 ]
  [[ "$output" == *'is not set'* ]]
  [ ! -s "$STUB_LOG" ]
}

@test 'does nothing when SENTINEL_UPGRADE_SCAN is 0' {
  SENTINEL_UPGRADE_SCAN=0 scan
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test 'refuses a malformed key without calling anything or printing it' {
  SENTINEL_SCAN_KEY='sk_scan_short' scan
  [ "$status" -eq 1 ]
  [[ "$output" != *sk_scan_short* ]]
  [ ! -s "$STUB_LOG" ]
}

@test 'refuses a missing or malformed site UUID' {
  SENTINEL_SITE_UUID='not-a-uuid' scan
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_LOG" ]
}

@test 'refuses an API URL with a path' {
  SENTINEL_API_URL='https://sentinel.example/api/v1' scan
  [ "$status" -eq 1 ]
}

@test 'no database: tells Sentinel no_database and passes' {
  STUB_BOOTSTRAP='' scan
  [ "$status" -eq 0 ]
  grep -q '"reason":"no_database"' "$STUB_LOG"
  grep -q "curl url https://sentinel.example/api/v1/sites/$UUID/upgrade-readiness/scan" "$STUB_LOG"
  grep -q "curl header-file X-Scan-Key: $KEY" "$STUB_LOG"
  ! grep -q 'analyze' "$STUB_LOG"
}

@test 'no database and a closed route still passes' {
  STUB_BOOTSTRAP='' STUB_HTTP=404 scan
  [ "$status" -eq 0 ]
  [[ "$output" == *'scan route is closed'* ]]
}

@test 'old connector: tells Sentinel connector_outdated and fails' {
  STUB_CONNECTOR='1.5.0' scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"connector_outdated"' "$STUB_LOG"
  ! grep -q 'analyze' "$STUB_LOG"
}

@test 'connector not enabled: connector_outdated' {
  STUB_CONNECTOR='' scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"connector_outdated"' "$STUB_LOG"
}

@test 'Upgrade Status present: scans and reports without Composer' {
  scan
  [ "$status" -eq 0 ]
  ! grep -q '^composer' "$STUB_LOG"
  grep -q 'drush pm:enable upgrade_status --yes' "$STUB_LOG"
  grep -q 'drush upgrade_status:analyze --all' "$STUB_LOG"
  grep -q "drush sentinel_connector:upgrade-status --scan-report --scan-started=[0-9]*$" "$STUB_LOG"
  grep -q "report env key=set uuid=$UUID api=https://sentinel.example" "$STUB_LOG"
  ! grep -q '^curl' "$STUB_LOG"
}

@test 'scan exit code 3 (problems found) is a good scan' {
  STUB_ANALYZE_RC=3 scan
  [ "$status" -eq 0 ]
  grep -q 'sentinel_connector:upgrade-status --scan-report' "$STUB_LOG"
}

@test 'Upgrade Status missing: adds it, then restores composer files' {
  STUB_US_MISSING=1 scan
  [ "$status" -eq 0 ]
  grep -q 'composer require --dev --no-interaction --no-progress drupal/upgrade_status$' "$STUB_LOG"
  grep -q '"original": true' "$PROJECT/composer.json"
  grep -q '"original": true' "$PROJECT/composer.lock"
}

@test 'Upgrade Status missing: falls back to core-dev at the site core version' {
  STUB_US_MISSING=1 STUB_COMPOSER_FAIL_FIRST=1 scan
  [ "$status" -eq 0 ]
  grep -q 'drupal/core-dev:11.2.5' "$STUB_LOG"
  grep -q '"original": true' "$PROJECT/composer.json"
}

@test 'install fails: tells Sentinel install_failed, fails, restores files' {
  STUB_US_MISSING=1 STUB_COMPOSER_FAIL_ALL=1 scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"install_failed"' "$STUB_LOG"
  grep -q '"original": true' "$PROJECT/composer.json"
  grep -q '"original": true' "$PROJECT/composer.lock"
  ! grep -q 'analyze' "$STUB_LOG"
}

@test 'enable fails: install_failed' {
  STUB_ENABLE_RC=1 scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"install_failed"' "$STUB_LOG"
}

@test 'scan fails: tells Sentinel scan_failed and fails' {
  STUB_ANALYZE_RC=1 scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"scan_failed"' "$STUB_LOG"
  ! grep -q 'sentinel_connector:upgrade-status' "$STUB_LOG"
}

@test 'the connector exit code is the result' {
  STUB_REPORT_RC=1 scan
  [ "$status" -eq 1 ]
}

@test 'a refused key is explained' {
  STUB_ENABLE_RC=1 STUB_HTTP=401 scan
  [ "$status" -eq 1 ]
  [[ "$output" == *'refused the scan key'* ]]
}

@test 'the key never reaches the output' {
  STUB_ANALYZE_RC=1 STUB_HTTP=500 scan
  [[ "$output" != *"$KEY"* ]]
  STUB_BOOTSTRAP='' scan
  [[ "$output" != *"$KEY"* ]]
}

@test 'the connector API URL is used when no URL is given' {
  unset SENTINEL_API_URL
  SENTINEL_CONNECTOR_API_BASE_URL='https://uat.example/' scan
  [ "$status" -eq 0 ]
  grep -q 'api=https://uat.example$' "$STUB_LOG"
}

@test 'production is the default API URL' {
  unset SENTINEL_API_URL
  STUB_BOOTSTRAP='' scan
  grep -q "curl url https://ingest.sentinelconnector.io/api/v1/sites/$UUID/upgrade-readiness/scan" "$STUB_LOG"
}

@test 'Drush that does not run fails without reporting' {
  STUB_DRUSH_BROKEN=1 scan
  [ "$status" -eq 1 ]
  [[ "$output" == *'Drush does not run here'* ]]
  ! grep -q '^curl' "$STUB_LOG"
}

@test 'refuses a remote http:// API URL' {
  SENTINEL_API_URL='http://sentinel.example' scan
  [ "$status" -eq 1 ]
  [ ! -s "$STUB_LOG" ]
}

@test 'allows http:// for localhost' {
  SENTINEL_API_URL='http://localhost:8000' STUB_BOOTSTRAP='' scan
  [ "$status" -eq 0 ]
  grep -q 'curl url http://localhost:8000/api/v1/' "$STUB_LOG"
}

@test 'problem reports follow the connector URL when none is given' {
  unset SENTINEL_API_URL
  STUB_CONNECTOR_URL='https://uat-ingest.example' STUB_ANALYZE_RC=1 scan
  [ "$status" -eq 1 ]
  grep -q 'curl url https://uat-ingest.example/api/v1/' "$STUB_LOG"
}

@test 'a given URL that settings.php overrides stops before anything is sent' {
  STUB_CONNECTOR_URL='https://uat-ingest.example' scan
  [ "$status" -eq 1 ]
  [[ "$output" == *'not to https://sentinel.example'* ]]
  ! grep -q '^curl' "$STUB_LOG"
  ! grep -q 'analyze' "$STUB_LOG"
}

@test 'uninstalls the modules this run enabled' {
  scan
  [ "$status" -eq 0 ]
  grep -q 'drush pm:uninstall upgrade_status --yes' "$STUB_LOG"
}

@test 'leaves modules that were already enabled' {
  STUB_US_ENABLED=1 scan
  [ "$status" -eq 0 ]
  ! grep -q 'pm:uninstall' "$STUB_LOG"
}

@test 'uninstalls the added modules after a failed scan too' {
  STUB_ANALYZE_RC=1 scan
  [ "$status" -eq 1 ]
  grep -q 'drush pm:uninstall upgrade_status --yes' "$STUB_LOG"
}

@test 'finds the Composer root from Drupal when run elsewhere' {
  mkdir -p "$PROJECT/web" "$BATS_TEST_TMPDIR/elsewhere"
  SENTINEL_PROJECT_DIR="$BATS_TEST_TMPDIR/elsewhere" STUB_ROOT="$PROJECT/web" STUB_US_MISSING=1 scan
  [ "$status" -eq 0 ]
  grep -q '"original": true' "$PROJECT/composer.json"
  [ ! -f "$BATS_TEST_TMPDIR/elsewhere/composer.json" ]
}

@test 'Drush that cannot find the site fails without reporting' {
  STUB_ROOT='' scan
  [ "$status" -eq 1 ]
  [[ "$output" == *'cannot find the Drupal site'* ]]
  ! grep -q '^curl' "$STUB_LOG"
}

@test 'an invalid connector URL stops before anything is sent' {
  unset SENTINEL_API_URL
  STUB_CONNECTOR_URL='INVALID' scan
  [ "$status" -eq 1 ]
  [[ "$output" == *'API URL is not valid'* ]]
  ! grep -q '^curl' "$STUB_LOG"
  ! grep -q 'analyze' "$STUB_LOG"
}

@test 'an outdated connector is reported to the connector URL' {
  unset SENTINEL_API_URL
  STUB_CONNECTOR_URL='https://uat-ingest.example' STUB_CONNECTOR='1.5.0' scan
  [ "$status" -eq 1 ]
  grep -q 'curl url https://uat-ingest.example/api/v1/' "$STUB_LOG"
}

@test 'without a given URL the connector keeps its own setting' {
  unset SENTINEL_API_URL
  STUB_CONNECTOR_URL='https://uat-ingest.example' scan
  [ "$status" -eq 0 ]
  grep -q 'report env key=set uuid=.* api=unset$' "$STUB_LOG"
}

@test 'a locked Upgrade Status is installed from the lock file' {
  STUB_US_MISSING=1 STUB_LOCKED=1 scan
  [ "$status" -eq 0 ]
  grep -q '^composer install --no-interaction --no-progress$' "$STUB_LOG"
  ! grep -q '^composer require' "$STUB_LOG"
}

@test 'a database that connects but a site that does not start fails' {
  STUB_BOOTSTRAP='' STUB_DB='Connected' scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"scan_failed"' "$STUB_LOG"
}

@test 'refuses an install that changes a locked package' {
  echo '{"packages":[{"name":"drupal/core","version":"11.2.5"}]}' > "$PROJECT/composer.lock"
  echo '{"packages":[{"name":"drupal/core","version":"11.2.6"}],"packages-dev":[{"name":"drupal/upgrade_status","version":"4.3.10"}]}' > "$BATS_TEST_TMPDIR/after.lock"
  STUB_US_MISSING=1 STUB_LOCK_AFTER="$BATS_TEST_TMPDIR/after.lock" scan
  [ "$status" -eq 1 ]
  grep -q '"reason":"install_failed"' "$STUB_LOG"
  [[ "$output" == *'would change drupal/core'* ]]
  grep -q '11.2.5' "$PROJECT/composer.lock"
}

@test 'accepts an install that only adds packages' {
  echo '{"packages":[{"name":"drupal/core","version":"11.2.5"}]}' > "$PROJECT/composer.lock"
  echo '{"packages":[{"name":"drupal/core","version":"11.2.5"}],"packages-dev":[{"name":"drupal/upgrade_status","version":"4.3.10"}]}' > "$BATS_TEST_TMPDIR/after.lock"
  STUB_US_MISSING=1 STUB_LOCK_AFTER="$BATS_TEST_TMPDIR/after.lock" scan
  [ "$status" -eq 0 ]
}

@test 'a given URL in upper case matches the connector URL' {
  SENTINEL_API_URL='https://Sentinel.Example/' STUB_CONNECTOR_URL='https://sentinel.example' scan
  [ "$status" -eq 0 ]
}

@test 'gitlab/scan.yml pins the SHA-256 of scan.sh' {
  if command -v sha256sum > /dev/null; then
    sum="$(sha256sum "$ROOT/scan.sh" | cut -d' ' -f1)"
  else
    sum="$(shasum -a 256 "$ROOT/scan.sh" | cut -d' ' -f1)"
  fi
  grep -q "SENTINEL_UPGRADE_SCAN_SHA256: $sum" "$ROOT/gitlab/scan.yml"
}
