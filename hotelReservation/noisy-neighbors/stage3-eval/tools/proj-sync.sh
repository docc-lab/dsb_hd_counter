#!/bin/bash
# proj-sync.sh -- keep experiment data on the CloudLab project directory (/proj/<project>),
# which is an NFS export that survives the experiment, every INTERVAL seconds while some
# process matching WHILE is alive, then one final pass.  Run it detached on the node that
# holds the data (usually node-0):
#
#   DST=/proj/tracing-pythia-PG0/royno7-hc-archive-$(date -u +%F) \
#   SRC="data/motiv3 data/collect-xyz" WHILE='queue-[a-z0-9]*\.sh' \
#   setsid nohup tools/proj-sync.sh > /tmp/proj-sync.log 2>&1 < /dev/null &
#
# Facts that cost time to learn (2026-11-02):
#  - /proj/<project> is persistent but PER SITE (ops.wisc vs ops.clemson are different
#    filesystems).  A copy made at Wisconsin is not visible from a Clemson experiment; to
#    move it across sites rsync from a node of the other site (ssh key from node to node).
#  - /users/<you> on the nodes is LOCAL disk, not NFS: it dies with the experiment.
#  - Group permissions: the dir is created with the project group; other members of the
#    project can read it.
#  - Never kill this script with `pkill -f proj-sync` typed in a shell whose own command
#    line contains the pattern; use the [p]roj-sync trick or kill the pid from the log.
#
# Env:
#   DST       destination directory under /proj (required)
#   SRC       space-separated dirs/files to mirror, relative to SRC_ROOT (default: data/*)
#   SRC_ROOT  default: the stage3-eval directory this script lives in
#   EXTRA     extra files copied flat into $DST (default: /tmp/queue*.log score-verify/*.json|csv|log)
#   WHILE     pgrep -f pattern; sync repeats while it matches (default: run-motiv2|run-collect|queue-)
#   INTERVAL  seconds between passes (default 600)
#   EXCLUDE   rsync exclude pattern (default: 'stage3eval_tmp*')
set -u
SRC_ROOT=${SRC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
DST=${DST:?set DST=/proj/<project>/<dir>}
SRC=${SRC:-"$(cd "$SRC_ROOT" && ls -d data/* 2>/dev/null | tr '\n' ' ')"}
EXTRA=${EXTRA:-"/tmp/queue*.log $SRC_ROOT/score-verify/*.json $SRC_ROOT/score-verify/*.csv $SRC_ROOT/score-verify/*.log"}
WHILE=${WHILE:-'run-motiv[2]|run-collec[t]|queue-[a-z0-9]*\.sh'}
INTERVAL=${INTERVAL:-600}
EXCLUDE=${EXCLUDE:-'stage3eval_tmp*'}
log() { echo "[$(date -u "+%F %H:%M:%S")] $*"; }
sync_once() {
    mkdir -p "$DST/data" "$DST/logs" "$DST/archive" || { log "cannot create $DST"; return 1; }
    for s in $SRC; do
        [ -e "$SRC_ROOT/$s" ] || continue
        nice -n 19 rsync -a --exclude "$EXCLUDE" "$SRC_ROOT/$s" "$DST/data/" 2>>"$DST/logs/rsync-errors.log"
    done
    for f in $EXTRA; do [ -e "$f" ] && cp -p "$f" "$DST/logs/" 2>/dev/null; done
    [ -d /local/archive ] && nice -n 19 rsync -a /local/archive/ "$DST/archive/" 2>/dev/null
    ls /tmp/*.tgz >/dev/null 2>&1 && cp -p /tmp/*.tgz "$DST/archive/" 2>/dev/null
    log "synced $(du -sh "$DST" 2>/dev/null | cut -f1) -> $DST"
}
log "## proj-sync start: SRC_ROOT=$SRC_ROOT SRC=[$SRC] WHILE=$WHILE every ${INTERVAL}s"
sync_once
while pgrep -f "$WHILE" >/dev/null; do
    sleep "$INTERVAL"; sync_once
done
sync_once
( cd "$DST" && find . -name '*.tgz' -exec md5sum {} \; > MD5SUMS 2>/dev/null )
log "## proj-sync DONE (nothing matching '$WHILE' is running)"
