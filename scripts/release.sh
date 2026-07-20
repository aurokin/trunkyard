#!/usr/bin/env bash
# Cut a trunkyard release: tarball of bin/ libexec/ lib/ as a GitHub release
# asset, for installation via mise's github backend.
#
#   scripts/release.sh v0.1.0
set -euo pipefail

version="${1:?usage: release.sh <vX.Y.Z>}"
[[ "$version" == v* ]] || { echo "version must start with v" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
./tests/integration.sh >/dev/null

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/trunkyard"
cp -R bin libexec lib LICENSE "$stage/trunkyard/"
# Stamp the version the dispatcher reports. BSD/macOS sed — releases are cut
# from the author's Mac; GNU sed would need `sed -i` without the ''.
sed -i '' "s/\${TRUNKYARD_VERSION:-dev}/\${TRUNKYARD_VERSION:-$version}/" "$stage/trunkyard/bin/trunkyard"
grep -q "TRUNKYARD_VERSION:-$version" "$stage/trunkyard/bin/trunkyard" \
  || { echo "version stamp failed (dispatcher default line moved?)" >&2; exit 1; }
tar -czf "$stage/trunkyard.tar.gz" -C "$stage" trunkyard

# Idempotent on retry: skip tagging if the tag already points at HEAD.
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
  [[ "$(git rev-parse "refs/tags/$version^{commit}")" == "$(git rev-parse HEAD)" ]] \
    || { echo "tag $version exists and is not HEAD" >&2; exit 1; }
else
  git tag "$version"
fi
git push -q origin HEAD "$version"
# Retry-safe: create the release only if absent, then (re)upload the asset.
if ! gh release view "$version" >/dev/null 2>&1; then
  gh release create "$version" --title "$version" --notes "trunkyard $version"
fi
gh release upload "$version" "$stage/trunkyard.tar.gz" --clobber
echo "released $version"
