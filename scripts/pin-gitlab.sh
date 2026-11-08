#!/usr/bin/env bash
# Writes the release tag and the SHA-256 of scan.sh into gitlab/scan.yml.
# Run it in the release commit, before tagging: scripts/pin-gitlab.sh v1.0.0
set -euo pipefail

tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Usage: scripts/pin-gitlab.sh vX.Y.Z' >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
if command -v sha256sum > /dev/null 2>&1; then
  sum="$(sha256sum "$root/scan.sh" | cut -d' ' -f1)"
else
  sum="$(shasum -a 256 "$root/scan.sh" | cut -d' ' -f1)"
fi

sed -i.bak \
  -e "s/^\(    SENTINEL_UPGRADE_SCAN_REF:\).*/\1 $tag/" \
  -e "s/^\(    SENTINEL_UPGRADE_SCAN_SHA256:\).*/\1 $sum/" \
  "$root/gitlab/scan.yml"
rm -f "$root/gitlab/scan.yml.bak"
echo "gitlab/scan.yml now runs scan.sh $tag ($sum)."
