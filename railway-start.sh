#!/usr/bin/env bash
# Railway start script for OpenGrok (aalfath/opengrok-railway-template).
# - Caddy listens on $PORT and asks for a username and password (basic auth);
#   /healthz is open and answers once the OpenGrok web app is up.
# - Tomcat (the OpenGrok web app) listens on 127.0.0.1:8080 only.
# - railway-sync.sh clones the repos in OPENGROK_REPOS, pulls them and indexes
#   them every SYNC_PERIOD_MINUTES.
# - Java heaps and indexer threads are sized from the service's memory and CPU
#   limits, so it runs on Railway's 0.5 GB / 1 vCPU plan.
# - If Caddy, Tomcat or the sync loop stops, the container exits 1 so
#   Railway's ON_FAILURE restart policy starts it again.
set -uo pipefail

log() { echo "railway-start: $*"; }
die() { echo "railway-start: ERROR: $*" >&2; exit 1; }

export OG=/var/opengrok
export SRC=$OG/src DATA=$OG/data ETC=$OG/etc
export CONFIG=$ETC/configuration.xml
PORT="${PORT:-8000}"
[ "$PORT" = 8080 ] && die "PORT must not be 8080 (Tomcat uses it on loopback); use 8000"
USERNAME="${OPENGROK_USERNAME:-admin}"
PASSWORD="${OPENGROK_PASSWORD:-}"
[ -n "$PASSWORD" ] || die "OPENGROK_PASSWORD is empty; set it (the template generates one) so the UI is never open"
[ "${#PASSWORD}" -ge 12 ] || die "OPENGROK_PASSWORD must be at least 12 characters"

mkdir -p "$SRC" "$DATA" "$ETC" || die "cannot create directories in $OG (is the volume mounted there?)"
chown appuser:appgroup "$OG" "$SRC" "$DATA" "$ETC"
find "$SRC" "$DATA" "$ETC" -mindepth 1 -maxdepth 1 \( ! -user appuser -o ! -group appgroup \) -exec chown -R appuser:appgroup {} +

# ---- sizing from the cgroup ---------------------------------------------------
mem_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
if [ "$mem_bytes" = max ] || [ -z "$mem_bytes" ]; then mem_mb=2048; else mem_mb=$((mem_bytes / 1048576)); fi
cpus=2
if read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null && [ "$quota" != max ]; then
  cpus=$(( (quota + period - 1) / period ))
fi
[ "$cpus" -ge 1 ] || cpus=1
[ "$cpus" -le 8 ] || cpus=8
clamp() { local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; echo "$v"; }
web_heap=$(clamp $((mem_mb * 16 / 100)) 64 4096)
idx_heap=$(clamp $((mem_mb * 24 / 100)) 96 8192)
rambuf=$(clamp $((idx_heap / 5)) 16 256)

JVM_COMMON="-XX:+UseSerialGC -XX:ActiveProcessorCount=$cpus -Xss512k -XX:MaxMetaspaceSize=96m -XX:ReservedCodeCacheSize=32m -XX:CompressedClassSpaceSize=24m -XX:MaxDirectMemorySize=32m -XX:+ExitOnOutOfMemoryError"
[ "$mem_mb" -lt 1500 ] && JVM_COMMON="$JVM_COMMON -XX:TieredStopAtLevel=1"
export CATALINA_OPTS="${OPENGROK_WEB_JAVA_OPTS:--Xms32m -Xmx${web_heap}m $JVM_COMMON}"
export INDEXER_JAVA_OPTS="${INDEXER_JAVA_OPTS:--Xms32m -Xmx${idx_heap}m $JVM_COMMON}"
export OPENGROK_INDEXER_RAMBUF_MB="${OPENGROK_INDEXER_RAMBUF_MB:-$rambuf}"
export OPENGROK_THREADS="${OPENGROK_THREADS:-$cpus}"
export SYNC_PERIOD_MINUTES="${SYNC_PERIOD_MINUTES:-30}"
export MALLOC_ARENA_MAX=2 GOMAXPROCS="$cpus"
log "memory ${mem_mb} MB, ${cpus} CPU: web heap ${web_heap} MB, indexer heap ${idx_heap} MB, index buffer ${OPENGROK_INDEXER_RAMBUF_MB} MB, sync every ${SYNC_PERIOD_MINUTES} min"

# ---- internal API token (indexer -> web app) and base configuration -------------
TOKEN_FILE=$ETC/railway-api-token
if [ ! -s "$TOKEN_FILE" ]; then
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
fi
chown appuser:appgroup "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
export TOKEN_FILE
export BASE_CONFIG=$ETC/railway-base.xml
( umask 077; cat > "$BASE_CONFIG" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<java version="21" class="java.beans.XMLDecoder">
 <object class="org.opengrok.indexer.configuration.Configuration">
  <void property="allowInsecureTokens"><boolean>true</boolean></void>
  <void property="authenticationTokens"><void method="add"><string>$(cat "$TOKEN_FILE")</string></void></void>
  <void property="indexerAuthenticationToken"><string>$(cat "$TOKEN_FILE")</string></void>
 </object>
</java>
XML
)
chown appuser:appgroup "$BASE_CONFIG"

# shellcheck disable=SC2086
indexer() { gosu appuser sh -c 'echo 1000 > /proc/self/oom_score_adj 2>/dev/null; exec java "$@"' sh $INDEXER_JAVA_OPTS -jar /opengrok/lib/opengrok.jar "$@"; }
export -f indexer

# Wipe an index written by an incompatible OpenGrok version (upstream's CHECK_INDEX).
if [ -s "$CONFIG" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
  indexer -R "$CONFIG" --checkIndex version >/dev/null 2>&1; rc=$?
  if [ "$rc" = 1 ]; then
    log "index was written by another OpenGrok version: removing it, a full reindex follows"
    find "$DATA" -mindepth 1 -maxdepth 1 -exec rm -r {} +
  fi
fi
# The web app needs a configuration file that carries the API token before it starts.
if ! grep -q "$(cat "$TOKEN_FILE")" "$CONFIG" 2>/dev/null; then
  log "writing the base configuration"
  indexer -R "$BASE_CONFIG" -s "$SRC" -d "$DATA" -c /usr/local/bin/ctags -H -P -S -W "$CONFIG" --noIndex >/dev/null 2>&1 \
    || die "the OpenGrok indexer could not write $CONFIG"
fi

# ---- Caddy: basic auth in front of Tomcat ---------------------------------------
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
stop_all() { kill -TERM "${pids[@]}" 2>/dev/null; pkill -TERM -f 'opengrok.jar' 2>/dev/null; }
trap 'trap - TERM INT; log "stopping"; stop_all; wait; exit 0' TERM INT

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
caddy_pid=$!; pids+=("$caddy_pid")

CATALINA_TMPDIR=/tmp gosu appuser /usr/local/tomcat/bin/catalina.sh run &
tomcat_pid=$!; pids+=("$tomcat_pid")

/usr/local/bin/railway-sync.sh &
sync_pid=$!; pids+=("$sync_pid")

# ---- watchdog: exit non-zero if a part stops --------------------------------------
while :; do
  sleep 5
  kill -0 "$caddy_pid" 2>/dev/null || { log "Caddy stopped"; break; }
  kill -0 "$tomcat_pid" 2>/dev/null || { log "Tomcat (OpenGrok web app) stopped"; break; }
  kill -0 "$sync_pid" 2>/dev/null || { log "the sync loop stopped"; break; }
done
stop_all
exit 1
