#!/usr/bin/env bash
# Railway start script for OpenGrok (aalfath/opengrok-railway-template).
# - Caddy listens on $PORT and asks for a username and password (basic auth);
#   /healthz is open and answers once the OpenGrok web app is up.
# - Tomcat (the web app) listens on 127.0.0.1:8080 only.
# - Java heaps, indexer threads and sync workers are sized from the service's
#   memory and CPU limits, so it runs on Railway's 0.5 GB / 1 vCPU plan.
# - Git repositories listed in OPENGROK_REPOS are cloned into the volume and
#   kept in sync by upstream's periodic mirror + reindex.
# - If Caddy, Tomcat or upstream's start program stops, the container exits 1
#   so Railway's ON_FAILURE policy restarts it.
set -uo pipefail

log() { echo "railway-start: $*"; }
die() { echo "railway-start: ERROR: $*" >&2; exit 1; }

VOL=/var/lib/opengrok
PORT="${PORT:-8000}"
[ "$PORT" = 8080 ] && die "PORT must not be 8080 (Tomcat uses it on loopback); use 8000"
USERNAME="${OPENGROK_USERNAME:-admin}"
PASSWORD="${OPENGROK_PASSWORD:-}"
[ -n "$PASSWORD" ] || die "OPENGROK_PASSWORD is empty; set it (the template generates one) so the UI is never open"
[ "${#PASSWORD}" -ge 12 ] || die "OPENGROK_PASSWORD must be at least 12 characters"

# ---- volume layout ---------------------------------------------------------
mkdir -p "$VOL/src" "$VOL/data" "$VOL/etc" "$VOL/clone-tmp" || die "cannot create directories in $VOL (is the volume mounted?)"
chown appuser:appgroup "$VOL" "$VOL/src" "$VOL/data" "$VOL/etc" "$VOL/clone-tmp"

# ---- sizing from the cgroup --------------------------------------------------
mem_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$mem_bytes" = max ] || [ -z "$mem_bytes" ]; then mem_mb=2048; else mem_mb=$((mem_bytes / 1048576)); fi
cpus=1
if read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null && [ "$quota" != max ]; then
  cpus=$(( (quota + period - 1) / period ))
else
  cpus=2
fi
[ "$cpus" -ge 1 ] || cpus=1
[ "$cpus" -le 8 ] || cpus=8

clamp() { local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; echo "$v"; }
web_heap=$(clamp $((mem_mb * 14 / 100)) 56 4096)
idx_heap=$(clamp $((mem_mb * 20 / 100)) 88 8192)
rambuf=$(clamp $((idx_heap / 6)) 16 256)
threads="$cpus"

JVM_COMMON="-XX:+UseSerialGC -XX:ActiveProcessorCount=$cpus -Xss512k -XX:MaxMetaspaceSize=96m -XX:ReservedCodeCacheSize=32m -XX:CompressedClassSpaceSize=24m -XX:MaxDirectMemorySize=32m -XX:+ExitOnOutOfMemoryError"
[ "$mem_mb" -lt 1500 ] && JVM_COMMON="$JVM_COMMON -XX:TieredStopAtLevel=1"

export CATALINA_OPTS="${OPENGROK_WEB_JAVA_OPTS:--Xms32m -Xmx${web_heap}m $JVM_COMMON}"
export INDEXER_JAVA_OPTS="${INDEXER_JAVA_OPTS:--Xms32m -Xmx${idx_heap}m $JVM_COMMON}"
export OPENGROK_INDEXER_RAMBUF_MB="${OPENGROK_INDEXER_RAMBUF_MB:-$rambuf}"
export INDEXER_OPT="${INDEXER_OPT:--T $threads --historyThreads $threads --historyFileThreads $threads}"
export WORKERS="${WORKERS:-1}"
export SYNC_PERIOD_MINUTES="${SYNC_PERIOD_MINUTES:-30}"
export API_TIMEOUT="${API_TIMEOUT:-30}"
export CHECK_INDEX="${CHECK_INDEX:-1}"
export GOMAXPROCS="$cpus"
export MALLOC_ARENA_MAX=2
log "memory ${mem_mb} MB, ${cpus} CPU: web heap ${web_heap} MB, indexer heap ${idx_heap} MB, index buffer ${OPENGROK_INDEXER_RAMBUF_MB} MB, sync every ${SYNC_PERIOD_MINUTES} min"

# Internal token for upstream's /reindex endpoint (port 5000, private network only).
if [ ! -s "$VOL/etc/railway-rest-token" ]; then
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$VOL/etc/railway-rest-token"
  chmod 600 "$VOL/etc/railway-rest-token"
fi
export REST_TOKEN="$(cat "$VOL/etc/railway-rest-token")"
# Upstream's entrypoint only fixes ownership one level deep through the symlinks; do etc fully.
find "$VOL/etc" "$VOL/data" -maxdepth 1 \( ! -user appuser -o ! -group appgroup \) -exec chown -R appuser:appgroup {} + 2>/dev/null
export REST_PORT="${REST_PORT:-5000}"

# ---- Caddy: basic auth in front of Tomcat ------------------------------------
hash=$(caddy hash-password --plaintext "$PASSWORD") || die "caddy hash-password failed"
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<CADDY
{
	admin off
	auto_https off
	persist_config off
	log {
		level WARN
	}
}
:${PORT} {
	handle /healthz {
		rewrite * /api/v1/system/ping
		reverse_proxy 127.0.0.1:8080
	}
	handle {
		basic_auth {
			${USERNAME} ${hash}
		}
		reverse_proxy 127.0.0.1:8080
	}
}
CADDY
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "invalid Caddyfile"

pids=()
cleanup() { trap - TERM INT; log "stopping"; kill -TERM "${pids[@]}" 2>/dev/null; wait; exit 0; }
trap cleanup TERM INT

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!; pids+=("$caddy_pid")

# ---- repositories (background: clone, then ask upstream to reindex) ----------
/usr/local/bin/railway-repos.sh &
pids+=("$!")

# ---- upstream start program (deploys the web app, starts Tomcat, syncs) -------
/scripts/entrypoint.sh /scripts/start.py &
og_pid=$!; pids+=("$og_pid")

# ---- watchdog: exit non-zero if a part stops -------------------------------------
# Keep the web app and the start program alive if memory runs out: the kernel
# then stops a reindex or a sync worker instead (they retry on the next sync).
protect() { for p in "$@"; do [ -n "$p" ] && echo -900 > "/proc/$p/oom_score_adj" 2>/dev/null; done; }
protect "$caddy_pid" "$og_pid" $(pgrep -f /scripts/start.py)
tomcat_seen=0; waited=0
while sleep 5; do
  kill -0 "$caddy_pid" 2>/dev/null || { log "Caddy stopped"; kill -TERM "$og_pid" 2>/dev/null; exit 1; }
  kill -0 "$og_pid" 2>/dev/null || { log "OpenGrok start program stopped"; kill -TERM "$caddy_pid" 2>/dev/null; exit 1; }
  if tc=$(pgrep -f org.apache.catalina.startup.Bootstrap); then
    [ "$tomcat_seen" = 1 ] || protect $tc $(pgrep -f /scripts/start.py)
    tomcat_seen=1
  elif [ "$tomcat_seen" = 1 ]; then
    log "Tomcat stopped"; kill -TERM "$og_pid" "$caddy_pid" 2>/dev/null; exit 1
  else
    waited=$((waited + 5))
    [ "$waited" -ge 900 ] && { log "Tomcat did not start in 15 minutes"; kill -TERM "$og_pid" "$caddy_pid" 2>/dev/null; exit 1; }
  fi
done
