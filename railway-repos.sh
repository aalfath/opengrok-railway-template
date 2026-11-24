#!/usr/bin/env bash
# Clone the Git repositories listed in OPENGROK_REPOS into the source root.
# Entries are separated by commas, spaces or new lines; each is a Git URL, or
# name=URL to choose the project name. Private repos: put a read-only token in
# the URL (https://x-access-token:TOKEN@github.com/org/repo.git).
# Repos that this script cloned earlier and that are no longer listed are removed.
# Updates of existing clones are done by upstream's periodic sync (git pull).
set -uo pipefail
VOL=/var/lib/opengrok
SRC=$VOL/src; TMP=$VOL/clone-tmp; LIST=$VOL/etc/railway-repos.list
log() { echo "railway-repos: $*" | sed -E 's#://[^/@ ]+@#://***@#g'; }
touch "$LIST"
rm -r "$TMP" 2>/dev/null; mkdir -p "$TMP"; chown appuser:appgroup "$TMP"

declare -A want=()
entries=$(printf '%s' "${OPENGROK_REPOS:-}" | tr ',\n\r\t' '    ')
for e in $entries; do
  case "$e" in
    *=*) name="${e%%=*}"; url="${e#*=}" ;;
    *)   url="$e"; name="${url%/}"; name="${name##*/}"; name="${name##*:}"; name="${name%.git}" ;;
  esac
  name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
  case "$name" in ""|.*) log "skipping entry with no usable name: $e"; continue ;; esac
  if [ -n "${want[$name]+x}" ]; then log "duplicate project name '$name', skipping $url"; continue; fi
  want[$name]="$url"
done

# Remove repos we cloned before that are no longer listed.
while read -r old; do
  [ -n "$old" ] || continue
  if [ -z "${want[$old]+x}" ] && [ -d "$SRC/$old" ]; then
    log "removing '$old' (no longer in OPENGROK_REPOS)"; rm -r "$SRC/$old"
  fi
done < "$LIST"

new=0; : > "$LIST.new"
for name in "${!want[@]}"; do
  url="${want[$name]}"
  if [ -d "$SRC/$name" ]; then echo "$name" >> "$LIST.new"; continue; fi
  log "cloning $url as '$name'"
  if gosu appuser env HOME="$VOL/etc" GIT_TERMINAL_PROMPT=0 git clone --quiet "$url" "$TMP/$name" 2>&1 | sed -E 's#://[^/@ ]+@#://***@#g'; [ -d "$TMP/$name/.git" ]; then
    mv "$TMP/$name" "$SRC/$name" && echo "$name" >> "$LIST.new" && new=$((new + 1))
    log "cloned '$name'"
  else
    log "clone of '$name' failed; it will be retried on the next restart"; rm -r "$TMP/$name" 2>/dev/null
  fi
done
mv "$LIST.new" "$LIST"
[ "$new" -gt 0 ] || exit 0

# Ask upstream to sync and index now instead of waiting for the next period.
for i in $(seq 1 60); do
  r=$(curl -s -m 5 -H "Authorization: Bearer $REST_TOKEN" "http://127.0.0.1:${REST_PORT:-5000}/reindex" 2>/dev/null)
  case "$r" in "Reindex triggered"*) log "reindex triggered for $new new repo(s)"; exit 0 ;; esac
  sleep 5
done
log "could not trigger a reindex; new repos will be indexed on the next periodic sync"
