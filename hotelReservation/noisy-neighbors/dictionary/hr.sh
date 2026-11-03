#!/bin/bash
# Phase B driver: per-endpoint dictionary on HotelReservation (PHASEB-HANDOFF.md section 3).
# Runs on the cluster head node (node-0). Subcommands:
#
#   hr.sh build [TAG]          build+push the instrumented HR image (all services, gordion recorder,
#                              PERF_HOOKS switch) and the hrgen load generator
#   hr.sh place                one-time: move the databases/memcached off the service node
#   hr.sh deploy RUN           (re)deploy every HR service with recorder output /data/RUN-<svc>.jsonl;
#                              the SUT pinned on NODE/CPUSET, the others spread over the other workers
#   hr.sh run NAME -- <hrgen args>   deploy + hrgen (pinned on WLGEN_NODE) + collect; RUN = <ts>-NAME
#   hr.sh collect RUN          copy every service's recorder files into RESULTS/RUN/
#   hr.sh stock                restore the stock image/placement (no recorder)
#
# Env: TAG=gordion1 SUT=frontend NODE=node-4 CPUSET=2-5 WLGEN_NODE=node-4 WLGEN_CPUS=1,6,7
#      AGGR="search geo rate" colocates+pins those services on the SUT's cores (stage-3 aggressor, F9)
#      WINDOW_MS=100 RAW=1 DISABLE=0 (GORDION_DISABLE for the B0 overhead run) PERF_HOOKS=0
#      STRESSOR=none|aggressor|capacity-cut (label in meta.json, F9) JAEGER_SAMPLE_RATIO=0
set -euo pipefail

HR=${HR:-/local/hr/hotelReservation}
REGISTRY=${REGISTRY:-10.10.1.1:5000}
RESULTS=${RESULTS:-/local/results/hr}
TAG=${TAG:-gordion1}
SUT=${SUT:-frontend}
NODE=${NODE:-node-4}
CPUSET=${CPUSET:-2-5}
WLGEN_NODE=${WLGEN_NODE:-node-4}
WLGEN_CPUS=${WLGEN_CPUS:-1,6,7}
WINDOW_MS=${WINDOW_MS:-100}
RAW=${RAW:-1}
DISABLE=${DISABLE:-0}
GATE=${GATE:-1}            # Phase D G-A: admission gate in the recorder (GORDION_GATE); 0 = off
GATE_CAP=${GATE_CAP:-}
PERF_HOOKS=${PERF_HOOKS:-0}
STRESSOR=${STRESSOR:-none}
JAEGER_SAMPLE_RATIO=${JAEGER_SAMPLE_RATIO:-0}
OTHER_NODES=${OTHER_NODES:-node-1,node-2,node-3}
DB_NODE=${DB_NODE:-node-3}
SERVICES="frontend search geo rate profile recommendation user reservation"
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

hostdir() { if [ "$1" = "node-4" ]; then echo /mnt/extra/gordion; else echo /var/tmp/gordion; fi; }
container() { echo "hotel-reserv-$1"; }

cmd_build() {
  local tag=${1:-$TAG}
  log "docker build $REGISTRY/hr-gordion:$tag"
  (cd $HR && docker build -q -t $REGISTRY/hr-gordion:$tag . && docker push -q $REGISTRY/hr-gordion:$tag)
  (cd $HR && CGO_ENABLED=0 go build -mod=vendor -o $HR/hrgen ./cmd/hrgen && ls -la $HR/hrgen)
  curl -s http://$REGISTRY/v2/hr-gordion/tags/list; echo
}

# move stateful pods off the service node (their data is re-seeded by the services on restart)
cmd_place() {
  for d in mongodb-geo mongodb-profile mongodb-rate mongodb-recommendation mongodb-reservation mongodb-user memcached-profile memcached-rate memcached-reserve consul jaeger; do
    kubectl patch deployment $d -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$DB_NODE\"}}}}}" >/dev/null
  done
  for d in mongodb-geo mongodb-profile mongodb-rate mongodb-recommendation mongodb-reservation mongodb-user memcached-profile memcached-rate memcached-reserve consul; do
    kubectl rollout status deployment/$d --timeout=180s >/dev/null
  done
  kubectl get pods -o wide | grep -E "mongo|memcached|consul"
}

# deploy one service with the recorder configured for run $1
deploy_svc() {
  local run=$1 svc=$2 node=$3 pin=$4
  local hd; hd=$(hostdir $node)
  ssh -o BatchMode=yes $node "sudo mkdir -p $hd && sudo chmod 777 $hd" >/dev/null
  local cmd="[\"$svc\"]"
  # an unpinned service must not keep the GOMAXPROCS of an earlier turn as the pinned SUT (strategic merge keeps env
  # entries by name): with the Phase D gate, GOMAXPROCS=4 on a 72-core node caps its handlers at 3 (reservation collapsed
  # at 5000 req/s while the frontend was the SUT, 2026-11-02 d-b-explore)
  local gomax=",{\"name\":\"GOMAXPROCS\",\"\$patch\":\"delete\"}"
  if [ "$pin" = "1" ]; then
    cmd="[\"sh\",\"-c\",\"exec taskset -c $CPUSET $svc\"]"
    gomax=",{\"name\":\"GOMAXPROCS\",\"value\":\"$(python3 -c "import sys;cs='$CPUSET';n=0
for p in cs.split(','):
  a,_,b=p.partition('-'); n+= (int(b)-int(a)+1) if b else 1
print(n)")\"}"
  fi
  # strategic merge: env/volumes merge by name, command is replaced
  kubectl patch deployment $svc -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"gordion/run\":\"$run\"}},\"spec\":{
    \"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"},
    \"volumes\":[{\"name\":\"gordion\",\"hostPath\":{\"path\":\"$hd\",\"type\":\"DirectoryOrCreate\"}}],
    \"containers\":[{\"name\":\"$(container $svc)\",\"image\":\"$REGISTRY/hr-gordion:$TAG\",\"imagePullPolicy\":\"Always\",\"command\":$cmd,
      \"env\":[{\"name\":\"GORDION_OUT\",\"value\":\"/data/$run-$svc.jsonl\"},{\"name\":\"GORDION_CLIENT_OUT\",\"value\":\"/data/$run-$svc-client.jsonl\"},
              {\"name\":\"GORDION_WINDOW_MS\",\"value\":\"$WINDOW_MS\"},{\"name\":\"GORDION_RAW\",\"value\":\"$RAW\"},{\"name\":\"GORDION_DISABLE\",\"value\":\"$DISABLE\"},{\"name\":\"GORDION_GATE\",\"value\":\"$GATE\"},{\"name\":\"GORDION_GATE_CAP\",\"value\":\"$GATE_CAP\"},
              {\"name\":\"PERF_HOOKS\",\"value\":\"$PERF_HOOKS\"},{\"name\":\"JAEGER_SAMPLE_RATIO\",\"value\":\"$JAEGER_SAMPLE_RATIO\"}$gomax],
      \"volumeMounts\":[{\"name\":\"gordion\",\"mountPath\":\"/data\"}]}]}}}}" >/dev/null
  # no CFS quota on any service (pinning does the isolation)
  kubectl patch deployment $svc --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{}}]' >/dev/null
}

# AGGR="search geo rate": stage-3 style HotelReservation aggressor pods = other HR services
# colocated on the SUT's node and pinned to the SUT's cores, driven by the same end-to-end
# workload (label STRESSOR=aggressor in meta.json; F9)
AGGR=${AGGR:-}

cmd_deploy() {
  local run=$1
  IFS=',' read -r -a others <<< "$OTHER_NODES"
  local i=0
  for svc in $SERVICES; do
    if [ "$svc" = "$SUT" ]; then
      deploy_svc $run $svc $NODE 1
    elif [[ " $AGGR " == *" $svc "* ]]; then
      deploy_svc $run $svc $NODE 1
    else
      deploy_svc $run $svc ${others[$((i % ${#others[@]}))]} 0
      i=$((i + 1))
    fi
  done
  for svc in $SERVICES; do
    kubectl rollout status deployment/$svc --timeout=240s >/dev/null
  done
  local ip; ip=$(kubectl get svc frontend -o jsonpath='{.spec.clusterIP}')
  for i in $(seq 1 60); do
    if curl -s -o /dev/null -m 2 "http://$ip:5000/hotels?inDate=2015-04-10&outDate=2015-04-12&lat=38.0&lon=-122.1"; then break; fi
    sleep 2
  done
  kubectl get pods -o wide | grep -E "^(frontend|search|geo|rate|profile|recommendation|user|reservation)-" | awk '{print $1, $7}' | tr '\n' ';' >&2; echo >&2
  echo $ip
}

cmd_wlgen() {
  local run=$1; shift
  [ "${1:-}" = "--" ] && shift
  local ip; ip=$(kubectl get svc frontend -o jsonpath='{.spec.clusterIP}')
  mkdir -p $RESULTS/$run
  local q; q=$(printf '%q ' "$@")
  log "hrgen on $WLGEN_NODE (cpus $WLGEN_CPUS) -> http://$ip:5000 : $*"
  scp -q -o BatchMode=yes $HR/hrgen $WLGEN_NODE:/tmp/hrgen
  ssh -o BatchMode=yes $WLGEN_NODE "mkdir -p /tmp/wlres/$run && taskset -c $WLGEN_CPUS /tmp/hrgen -url http://$ip:5000 -out /tmp/wlres/$run/wlgen.jsonl $q 2>&1 | tail -3" >&2
  scp -q -o BatchMode=yes "$WLGEN_NODE:/tmp/wlres/$run/*" $RESULTS/$run/
  tail -1 $RESULTS/$run/wlgen.jsonl
}

cmd_collect() {
  local run=$1
  mkdir -p $RESULTS/$run
  sleep 1
  for svc in $SERVICES; do
    local node; node=$(kubectl get pod -l io.kompose.service=$svc -o jsonpath='{.items[0].spec.nodeName}')
    local hd; hd=$(hostdir $node)
    scp -q -o BatchMode=yes "$node:$hd/$run-$svc.jsonl" $RESULTS/$run/$svc.jsonl 2>/dev/null || true
    scp -q -o BatchMode=yes "$node:$hd/$run-$svc-client.jsonl" $RESULTS/$run/$svc-client.jsonl 2>/dev/null || true
  done
  # the SUT's file under the name the analysis scripts expect; all callers' client streams in one file
  cp $RESULTS/$run/$SUT.jsonl $RESULTS/$run/gordion.jsonl
  cat $RESULTS/$run/*-client.jsonl > $RESULTS/$run/callers-client.jsonl 2>/dev/null || true
  local c0=${CPUSET%%[-,]*}
  local cpufreq; cpufreq=$(ssh -o BatchMode=yes $NODE "cd /sys/devices/system/cpu/cpu$c0/cpufreq 2>/dev/null && echo \$(cat scaling_driver) \$(cat scaling_governor) \$(cat scaling_cur_freq)" 2>/dev/null || echo none)
  local idle; idle=$(ssh -o BatchMode=yes $NODE "pgrep -c -f 'chrt --idle' 2>/dev/null || true")
  cat > $RESULTS/$run/meta.json <<EOF
{"run":"$run","testbed":"hotelreservation","sut":"$SUT","node":"$NODE","cpuset":"$CPUSET","tag":"$TAG","window_ms":$WINDOW_MS,"raw":"$RAW","disable":"$DISABLE",
 "perf_hooks":"$PERF_HOOKS","jaeger_sample_ratio":"$JAEGER_SAMPLE_RATIO","wlgen_node":"$WLGEN_NODE","wlgen_cpus":"$WLGEN_CPUS",
 "stressor":"$STRESSOR","aggressors":"$AGGR","cpufreq":"$cpufreq","sched_idle_fillers":"${idle:-0}",
 "gate":"$GATE","gate_cap":"$GATE_CAP","nominal_mhz":"${NOMINAL_MHZ:-}",
 "placement":"$(kubectl get pods -o wide | grep -E '^(frontend|search|geo|rate|profile|recommendation|user|reservation)-' | awk '{printf "%s=%s ", $1, $7}')",
 "collected":"$(date -Is)"}
EOF
  log "collected: $(wc -l < $RESULTS/$run/gordion.jsonl) recorder lines ($SUT), $(wc -l < $RESULTS/$run/wlgen.jsonl) hrgen lines -> $RESULTS/$run"
}

cmd_run() {
  local name=$1; shift
  local run="$(date +%Y%m%d-%H%M%S)-$name"
  cmd_deploy $run >/dev/null
  sleep 3
  cmd_wlgen $run "$@"
  cmd_collect $run
  echo $run
}

cmd_stock() {
  for svc in $SERVICES; do
    kubectl patch deployment $svc --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"deathstarbench/hotel-reservation:latest\"},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/command\",\"value\":[\"$svc\"]},{\"op\":\"remove\",\"path\":\"/spec/template/spec/nodeSelector\"}]" >/dev/null || true
  done
}

sub=${1:-}; shift || true
case "$sub" in
  build)   cmd_build "$@";;
  place)   cmd_place;;
  deploy)  cmd_deploy "$@";;
  wlgen)   cmd_wlgen "$@";;
  collect) cmd_collect "$@";;
  run)     cmd_run "$@";;
  stock)   cmd_stock;;
  *) sed -n 2,18p "$0"; exit 1;;
esac
