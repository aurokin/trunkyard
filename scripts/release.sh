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
# Stamp the version the dispatcher reports.
sed -i '' "s/\${TRUNKYARD_VERSION:-dev}/\${TRUNKYARD_VERSION:-$version}/" "$stage/trunkyard/bin/trunkyard"
tar -czf "$stage/trunkyard.tar.gz" -C "$stage" trunkyard

git tag "$version"
git push -q origin HEAD "$version"
gh release create "$version" "$stage/trunkyard.tar.gz" --title "$version" --notes "trunkyard $version"
echo "released $version"
