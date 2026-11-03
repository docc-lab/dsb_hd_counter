#!/bin/bash
# Phase C driver: per-endpoint dictionary on DSB SocialNetwork (PHASEC-HANDOFF.md section 2 A3 / 3 B-SN).
# Runs on the cluster head node (node-0). Subcommands:
#
#   sn.sh build [TAG]       build+push the instrumented image (all C++ services, gordion recorder in
#                           home-timeline / user-timeline / post-storage) and the hrgen load generator (-app sn)
#   sn.sh install           helm-install the chart (release "sn", C++ services from the local registry, no CFS
#                           limits), then load the socfb-Reed98 social graph with --compose
#   sn.sh deploy RUN        (re)deploy the SUT with the recorder writing /data/RUN-<svc>.jsonl, pinned on
#                           NODE/CPUSET; the other instrumented services get a recorder too (unpinned)
#   sn.sh run NAME -- <hrgen args>   deploy + hrgen (pinned on WLGEN_NODE) + collect; RUN = <ts>-NAME
#   sn.sh collect RUN       copy the recorder files into RESULTS/RUN/ (+ wlgen.jsonl, meta.json)
#   sn.sh uninstall         helm uninstall
#
# Env: TAG=g1 SUT=home-timeline-service NODE=node-4 CPUSET=2-3 WLGEN_NODE=node-4 WLGEN_CPUS=8-15
#      WINDOW_MS=100 RAW=1 DISABLE=0 STRESSOR=none|capacity-cut  DB_NODE=node-3 (datastores + nginx)
set -euo pipefail

NS=${NS:-sn}
SN=${SN:-/local/sn/gordion}
REGISTRY=${REGISTRY:-10.10.1.1:5000}
RESULTS=${RESULTS:-/local/results/sn}
TAG=${TAG:-g1}
SUT=${SUT:-home-timeline-service}
NODE=${NODE:-node-4}
CPUSET=${CPUSET:-2-3}
WLGEN_NODE=${WLGEN_NODE:-node-4}
WLGEN_CPUS=${WLGEN_CPUS:-8-15}
WINDOW_MS=${WINDOW_MS:-100}
RAW=${RAW:-1}
DISABLE=${DISABLE:-0}
STRESSOR=${STRESSOR:-none}
DB_NODE=${DB_NODE:-node-3}
OTHER_NODES=${OTHER_NODES:-node-1,node-2}
HRGEN=${HRGEN:-/local/hr/hotelReservation/hrgen}
CPP_SERVICES="compose-post-service home-timeline-service media-service post-storage-service social-graph-service text-service unique-id-service url-shorten-service user-mention-service user-service user-timeline-service"
# Phase F: text-service and compose-post-service carry a recorder too (image g4); INSTRUMENTED lists the services that get one
INSTRUMENTED=${INSTRUMENTED:-"home-timeline-service user-timeline-service post-storage-service text-service compose-post-service"}
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
hostdir() { if ssh -o BatchMode=yes $1 "[ -d /mnt/extra ]" 2>/dev/null; then echo /mnt/extra/gordion; else echo /var/tmp/gordion; fi; }

cmd_build() {
  local tag=${1:-$TAG}
  log "docker build $REGISTRY/sn-gordion:$tag"
  (cd $SN && docker build -q -t $REGISTRY/sn-gordion:$tag . && docker push -q $REGISTRY/sn-gordion:$tag)
  curl -s http://$REGISTRY/v2/sn-gordion/tags/list; echo
}

cmd_install() {
  local sets=""
  for s in $CPP_SERVICES; do
    sets="$sets --set $s.container.dockerRegistry=$REGISTRY --set $s.container.image=sn-gordion --set $s.container.imageVersion=$TAG --set $s.container.imagePullPolicy=Always"
  done
  # no CFS limits anywhere (pinning does the isolation); the chart's default is 100m per service
  # kubespray names the cluster DNS service "coredns", the chart assumes "kube-dns"
  local dns; dns=$(kubectl -n kube-system get svc -o name | grep -E "dns" | head -1 | sed 's#service/##')
  cat > /tmp/sn-values.yaml <<EOF
global:
  resources: null
  nginx:
    resolverName: ${dns:-kube-dns}.kube-system.svc.cluster.local
    workerProcesses: 16
  jaeger:
    samplerParam: 0
EOF
  helm upgrade --install sn -n $NS --create-namespace $SN/helm-chart/socialnetwork -f /tmp/sn-values.yaml $sets >/dev/null
  # "global.resources: null" does not drop the chart's 100m/128Mi defaults: strip the limits from every deployment
  for d in $(kubectl -n $NS get deployments -o name | sed 's#deployment.apps/##'); do
    kubectl -n $NS patch deployment $d --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{}}]' >/dev/null || true
  done
  log "waiting for the pods"
  for i in $(seq 1 90); do
    local notready; notready=$(kubectl -n $NS get pods --no-headers | grep -v -c "Running\|Completed" || true)
    [ "$notready" = "0" ] && break
    sleep 5
  done
  kubectl -n $NS get pods -o wide | grep -v -E "^(frontend|search|geo|rate|profile|recommendation|user|reservation|consul|jaeger|memcached-|mongodb-|hr-client|nfs)" >&2
  # datastores + nginx on DB_NODE, everything else off the service node
  for d in $(kubectl -n $NS get deployments -o name | grep -E "redis|mongodb|memcached|nginx-thrift|media-frontend|jaeger" | sed 's#deployment.apps/##'); do
    kubectl -n $NS patch deployment $d -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$DB_NODE\"}}}}}" >/dev/null || true
  done
  for d in $(kubectl -n $NS get deployments -o name | grep -E "redis|mongodb|memcached|nginx-thrift" | sed 's#deployment.apps/##'); do
    kubectl -n $NS rollout status deployment/$d --timeout=240s >/dev/null || true
  done
  # the datastores were just moved (their emptyDir data is gone): restart the C++ services so that they recreate
  # their MongoDB indexes BEFORE the graph is loaded (a unique index created after concurrent upserts fails with
  # duplicate keys and the service then loops at startup)
  for s in $CPP_SERVICES; do kubectl -n $NS rollout restart deployment/$s >/dev/null; done
  for s in $CPP_SERVICES; do kubectl -n $NS rollout status deployment/$s --timeout=240s >/dev/null || true; done
  sleep 10
  [ -f /local/sn/.graph-loaded ] || { cmd_graph && touch /local/sn/.graph-loaded; }
}

cmd_graph() {
  python3 -c "import aiohttp" 2>/dev/null || pip3 install --user -q aiohttp
  local ip; ip=$(kubectl -n $NS get svc nginx-thrift -o jsonpath='{.spec.clusterIP}')
  for i in $(seq 1 60); do curl -s -o /dev/null -m 3 "http://$ip:8080/" && break; sleep 3; done
  log "loading socfb-Reed98 into nginx $ip:8080 (register, follow, compose)"
  (cd $SN && python3 scripts/init_social_graph.py --graph socfb-Reed98 --ip $ip --port 8080 --compose 2>&1 | tail -3) >&2
}

cpus_of() { python3 -c "import sys;cs='$1';n=0
for p in cs.split(','):
  a,_,b=p.partition('-'); n+= (int(b)-int(a)+1) if b else 1
print(n)"; }

# service name -> binary in the image (the chart's container.command)
binary_of() {
  case "$1" in
    home-timeline-service) echo HomeTimelineService;; user-timeline-service) echo UserTimelineService;;
    post-storage-service) echo PostStorageService;; compose-post-service) echo ComposePostService;;
    social-graph-service) echo SocialGraphService;; user-service) echo UserService;; text-service) echo TextService;;
    unique-id-service) echo UniqueIdService;; url-shorten-service) echo UrlShortenService;; media-service) echo MediaService;;
    user-mention-service) echo UserMentionService;; *) echo "unknown service $1" >&2; exit 1;;
  esac
}

# (re)deploy one instrumented service with the recorder configured for run $1
deploy_svc() {
  local run=$1 svc=$2 node=$3 pin=$4
  local hd; hd=$(hostdir $node)
  ssh -o BatchMode=yes $node "sudo mkdir -p $hd && sudo chmod 777 $hd" >/dev/null
  local bin; bin=$(binary_of $svc)
  local cmd="[\"$bin\"]"
  [ "$pin" = "1" ] && cmd="[\"taskset\",\"-c\",\"$CPUSET\",\"$bin\"]"
  local cname; cname=$(kubectl -n $NS get deployment $svc -o jsonpath='{.spec.template.spec.containers[0].name}')
  kubectl -n $NS patch deployment $svc -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"gordion/run\":\"$run\"}},\"spec\":{
    \"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"},
    \"volumes\":[{\"name\":\"gordion\",\"hostPath\":{\"path\":\"$hd\",\"type\":\"DirectoryOrCreate\"}}],
    \"containers\":[{\"name\":\"$cname\",\"command\":$cmd,\"args\":[],
      \"env\":[{\"name\":\"GORDION_OUT\",\"value\":\"/data/$run-$svc.jsonl\"},{\"name\":\"GORDION_WINDOW_MS\",\"value\":\"$WINDOW_MS\"},
              {\"name\":\"GORDION_RAW\",\"value\":\"$RAW\"},{\"name\":\"GORDION_DISABLE\",\"value\":\"$DISABLE\"}],
      \"volumeMounts\":[{\"name\":\"gordion\",\"mountPath\":\"/data\"}]}]}}}}" >/dev/null
  kubectl -n $NS patch deployment $svc --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{}}]' >/dev/null
}

cmd_deploy() {
  local run=$1
  IFS=',' read -r -a others <<< "$OTHER_NODES"
  local i=0
  for svc in $INSTRUMENTED; do
    if [ "$svc" = "$SUT" ]; then deploy_svc $run $svc $NODE 1; else deploy_svc $run $svc ${others[$((i % ${#others[@]}))]} 0; i=$((i + 1)); fi
  done
  # the remaining C++ services off the service node
  for svc in $CPP_SERVICES; do
    case " $INSTRUMENTED " in *" $svc "*) continue;; esac
    kubectl -n $NS patch deployment $svc -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${others[$((i % ${#others[@]}))]}\"}}}}}" >/dev/null
    i=$((i + 1))
  done
  for svc in $CPP_SERVICES; do kubectl -n $NS rollout status deployment/$svc --timeout=240s >/dev/null; done
  local ip; ip=$(kubectl -n $NS get svc nginx-thrift -o jsonpath='{.spec.clusterIP}')
  for i in $(seq 1 60); do
    curl -s -o /dev/null -m 3 "http://$ip:8080/wrk2-api/home-timeline/read?user_id=1&start=0&stop=10" && break; sleep 2
  done
  kubectl -n $NS get pods -o wide | grep -E "^(home-timeline-service|user-timeline-service|post-storage-service|compose-post-service|text-service|nginx-thrift)-" | awk '{print $1, $7}' | tr '\n' ';' >&2; echo >&2
  echo $ip
}

cmd_wlgen() {
  local run=$1; shift
  [ "${1:-}" = "--" ] && shift
  local ip; ip=$(kubectl -n $NS get svc nginx-thrift -o jsonpath='{.spec.clusterIP}')
  mkdir -p $RESULTS/$run
  local q; q=$(printf '%q ' "$@")
  log "hrgen -app sn on $WLGEN_NODE (cpus $WLGEN_CPUS) -> http://$ip:8080 : $*"
  scp -q -o BatchMode=yes $HRGEN $WLGEN_NODE:/tmp/hrgen
  ssh -o BatchMode=yes $WLGEN_NODE "mkdir -p /tmp/wlres/$run && taskset -c $WLGEN_CPUS /tmp/hrgen -app sn -url http://$ip:8080 -out /tmp/wlres/$run/wlgen.jsonl $q 2>&1 | tail -3" >&2
  scp -q -o BatchMode=yes "$WLGEN_NODE:/tmp/wlres/$run/*" $RESULTS/$run/
  tail -1 $RESULTS/$run/wlgen.jsonl
}

cmd_collect() {
  local run=$1
  mkdir -p $RESULTS/$run
  sleep 1
  for svc in $INSTRUMENTED; do
    local node; node=$(kubectl -n $NS get pod -l service=$svc -o jsonpath='{.items[0].spec.nodeName}')
    local hd; hd=$(hostdir $node)
    scp -q -o BatchMode=yes "$node:$hd/$run-$svc.jsonl" $RESULTS/$run/$svc.jsonl 2>/dev/null || true
  done
  cp $RESULTS/$run/$SUT.jsonl $RESULTS/$run/gordion.jsonl
  local c0=${CPUSET%%[-,]*}
  local mhz; mhz=$(ssh -o BatchMode=yes $NODE "grep MHz /proc/cpuinfo | sed -n '$((c0 + 1))p' | awk '{print \$4}'" 2>/dev/null || echo 0)
  local idle; idle=$(ssh -o BatchMode=yes $NODE "pgrep -c -f 'chrt --idle' 2>/dev/null || true")
  cat > $RESULTS/$run/meta.json <<EOF
{"run":"$run","testbed":"socialnetwork","sut":"$SUT","node":"$NODE","cpuset":"$CPUSET","tag":"$TAG","window_ms":$WINDOW_MS,"raw":"$RAW","disable":"$DISABLE",
 "wlgen_node":"$WLGEN_NODE","wlgen_cpus":"$WLGEN_CPUS","stressor":"$STRESSOR","cpufreq":"none (hardware P-states; /proc/cpuinfo core $c0 = $mhz MHz at collect)","sched_idle_fillers":"${idle:-0}",
 "nominal_mhz":2400,
 "placement":"$(kubectl -n $NS get pods -o wide | grep -E '^(home-timeline-service|user-timeline-service|post-storage-service|compose-post-service|social-graph-service|nginx-thrift)-' | awk '{printf "%s=%s ", $1, $7}')",
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

sub=${1:-}; shift || true
case "$sub" in
  build)     cmd_build "$@";;
  install)   cmd_install;;
  graph)     cmd_graph;;
  deploy)    cmd_deploy "$@";;
  wlgen)     cmd_wlgen "$@";;
  collect)   cmd_collect "$@";;
  run)       cmd_run "$@";;
  uninstall) helm uninstall -n $NS sn;;
  *) sed -n 2,18p "$0"; exit 1;;
esac
