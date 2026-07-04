#!/bin/bash
# ===========================================================================
# clean-dbs.sh — standalone HR database + memcached hygiene
#
# The HR data services (rate/geo/profile/user/reservation/recommendation)
# unconditionally InsertMany their seed data on EVERY pod start (no dedupe,
# no unique index; mongo sits on PVCs so nothing self-clears). Each restart
# appends a full duplicate batch (rate +27, geo/profile/number/recommendation
# +80, user +501 docs), slowing queries and — for rate — re-inflating the
# memcached value cached per hotelId. This wrapper runs data-collector.sh's
# clean_hr_databases: probe each seeded DB against its seed baseline x
# HR_DB_BLOAT_FACTOR, and on bloat drop + re-seed + flush memcached tiers.
#
# Usage (from noisy-neighbors/):
#   ./clean-dbs.sh              # probe, reset only if bloated (factor 5)
#   ./clean-dbs.sh --force      # reset unconditionally
#   HR_DB_BLOAT_FACTOR=3 ./clean-dbs.sh
#
# Recommended cadence: before each stage-2 batch (see PRE_BATCH_DB_CLEAN in
# stage2-batch/run-batch.sh) and before stage-3 campaigns.
# ===========================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "${1:-}" == "--force" ]] && export HR_DB_FORCE_RESET=1

# Sourcing is safe: data-collector.sh only runs its main under a
# BASH_SOURCE guard. This gives us clean_hr_databases + log().
# shellcheck source=data-collector.sh
source "$DIR/data-collector.sh" >/dev/null 2>&1 || true
if ! declare -F clean_hr_databases >/dev/null; then
    echo "ERROR: could not source clean_hr_databases from $DIR/data-collector.sh" >&2
    exit 1
fi

# clean_hr_databases logs into "$exp_dir/logs/collector.log"; give it a
# scratch dir and echo the log afterwards.
exp_dir="$(mktemp -d /tmp/clean-dbs.XXXXXX)"
mkdir -p "$exp_dir/logs"

clean_hr_databases "$exp_dir"
rc=$?

echo "--- collector.log ---"
cat "$exp_dir/logs/collector.log" 2>/dev/null
rm -rf "$exp_dir"
exit $rc
