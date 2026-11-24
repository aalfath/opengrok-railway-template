#!/usr/bin/env bash
# Keeps the source root in line with OPENGROK_REPOS and indexes it.
# Entries are separated by commas, spaces or new lines. Each is a Git URL, or
# name=URL to choose the project name. Private repos: put a read-only token in
# the URL (https://x-access-token:TOKEN@github.com/org/repo.git).
# Every SYNC_PERIOD_MINUTES (0 = only at start): clone new repos, remove repos
# that this script cloned and that are no longer listed, git pull the others,
# then run the indexer, which pushes the new configuration to the web app.
set -uo pipefail
TMP=$OG/clone-tmp; LIST=$ETC/railway-repos.list
log() { echo "railway-sync: $*" | sed -E 's#://[^/@ ]+@#://***@#g'; }
asuser() { gosu appuser env HOME="$ETC" GIT_TERMINAL_PROMPT=0 sh -c 'echo 500 > /proc/self/oom_score_adj 2>/dev/null; exec "$@"' sh "$@"; }

# Wait for the web app (the indexer pushes its configuration to it).
for i in $(seq 1 180); do
  curl -s -o /dev/null -m 3 http://127.0.0.1:8080/api/v1/system/ping && break
  sleep 2
done

sync_repos() {
  declare -A want=()
  local entries e name url
  entries=$(printf '%s' "${OPENGROK_REPOS:-}" | tr ',\n\r\t' '    ')
  for e in $entries; do
    case "$e" in
      *=*) name="${e%%=*}"; url="${e#*=}" ;;
      *)   url="$e"; name="${url%/}"; name="${name##*/}"; name="${name##*:}"; name="${name%.git}" ;;
    esac
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
    case "$name" in ""|.*) log "skipping an entry with no usable name: $e"; continue ;; esac
    [ -n "${want[$name]+x}" ] && { log "duplicate project name '$name', skipping $url"; continue; }
    want[$name]="$url"
  done
  touch "$LIST"
  while read -r old; do
    [ -n "$old" ] && [ -z "${want[$old]+x}" ] || continue
    log "removing '$old' (no longer in OPENGROK_REPOS)"
    for d in "$SRC/$old" "$DATA"/*/"$old"; do [ -e "$d" ] && rm -r "$d"; done
  done < "$LIST"
  : > "$LIST.new"
  for name in "${!want[@]}"; do
    url="${want[$name]}"
    if [ -d "$SRC/$name/.git" ]; then
      echo "$name" >> "$LIST.new"
      (cd "$SRC/$name" && asuser timeout 900 git pull --ff-only --quiet) 2>&1 | sed -E 's#://[^/@ ]+@#://***@#g' \
        || log "git pull of '$name' failed; keeping the current copy"
      continue
    fi
    [ -e "$SRC/$name" ] && { log "'$SRC/$name' exists and is not a Git clone; leaving it alone"; echo "$name" >> "$LIST.new"; continue; }
    log "cloning $url as '$name'"
    rm -r "$TMP" 2>/dev/null; mkdir -p "$TMP"; chown appuser:appgroup "$TMP"
    if asuser timeout 1800 git clone --quiet "$url" "$TMP/$name" 2>&1 | sed -E 's#://[^/@ ]+@#://***@#g'; [ -d "$TMP/$name/.git" ]; then
      mv "$TMP/$name" "$SRC/$name" && echo "$name" >> "$LIST.new"; log "cloned '$name'"
    else
      log "clone of '$name' failed; it is retried on the next sync"
    fi
  done
  rm -r "$TMP" 2>/dev/null
  mv "$LIST.new" "$LIST"
}

run_indexer() {
  local t0=$SECONDS rc
  log "indexing"
  # shellcheck disable=SC2086
  indexer -R "$BASE_CONFIG" -s "$SRC" -d "$DATA" -c /usr/local/bin/ctags \
    -P -S -H -G --remote on --leadingWildCards on \
    -m "$OPENGROK_INDEXER_RAMBUF_MB" -T "$OPENGROK_THREADS" \
    --historyThreads "$OPENGROK_THREADS" --historyFileThreads "$OPENGROK_THREADS" \
    ${INDEXER_OPT:-} -W "$CONFIG" -U http://127.0.0.1:8080/ --token "@$TOKEN_FILE" \
    2>&1 | grep -E 'SEVERE|ERROR|Exception|Done indexing|OutOfMemory' | grep -v -E '^\s+at ' | head -40
  rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ]; then log "indexing done in $((SECONDS - t0)) s"; else log "indexer exited with $rc after $((SECONDS - t0)) s; retried on the next sync"; fi
}

while :; do
  sync_repos
  run_indexer
  [ "$SYNC_PERIOD_MINUTES" -gt 0 ] 2>/dev/null || { log "periodic sync is off"; exec sleep infinity; }
  sleep $((SYNC_PERIOD_MINUTES * 60))
done
