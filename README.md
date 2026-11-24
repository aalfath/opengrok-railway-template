[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/opengrok?utm_medium=integration&utm_source=button&utm_campaign=opengrok)

# Deploy and Host OpenGrok on Railway

OpenGrok is Oracle's open-source (CDDL-1.0) source-code search and cross-reference engine. It indexes your Git repositories and gives you a fast web UI for full-text, definition, symbol, path and history search, with syntax-highlighted, cross-linked source, blame and diffs across many projects at once.

## About Hosting OpenGrok

This template runs OpenGrok 1.14.21 from the official `opengrok/docker` image as one service. You list Git URLs in `OPENGROK_REPOS`. On every start, and then every 30 minutes, the service clones new repositories, pulls the existing ones and reindexes them. Source, index and configuration live on one Railway volume, so restarts don't re-clone or reindex from scratch. OpenGrok has no login of its own, so Caddy in front of it asks for a username and a generated password. Java heaps and indexer threads are sized from the service's limits, so it runs on 0.5 GB of RAM.

## Common Use Cases

* Search and browse code across all of a team's Git repositories in one place
* Find where a function, symbol or config key is defined and every place it's used
* Read file history, blame and diffs in the browser without cloning anything

## Dependencies for OpenGrok Hosting

* A Railway volume at `/var/opengrok` (included) for source clones, the index and the configuration
* Git repositories reachable over HTTPS from Railway (public, or private with a read-only token in the URL)

### Deployment Dependencies

* OpenGrok source and docs: https://github.com/oracle/opengrok
* Docker image docs: https://github.com/oracle/opengrok/tree/1.14.21/docker
* Template repo: https://github.com/aalfath/opengrok-railway-template

### Implementation Details

**Services:** one service, `OpenGrok`. Caddy listens on port 8000 with basic auth and proxies to the OpenGrok web app (Tomcat on localhost). A sync loop clones, pulls and indexes the repositories. The health check `/healthz` is the only path without a login. The volume is mounted at `/var/opengrok`.

**After deploy:**

1. Open the Railway URL. Sign in as `admin` with the password from the service's `OPENGROK_PASSWORD` variable (Variables tab).
2. The template starts with one small example repository (hiredis), so search works within about a minute.
3. To index your own code, set `OPENGROK_REPOS` to your Git URLs, separated by commas, spaces or new lines. Use `name=URL` to choose a project name. For a private repo, put a read-only token in the URL, for example `https://x-access-token:YOUR-TOKEN@github.com/YOUR-ORG/YOUR-REPO.git`. Redeploy to apply the change. Repositories you remove from the list are deleted from the volume and the index.

**Optional variables:** `SYNC_PERIOD_MINUTES` (default 30; `0` syncs only at start), `OPENGROK_USERNAME` (default `admin`) and `INDEXER_OPT` for extra indexer flags, such as `-i d:vendor` to skip `vendor` folders.

**Memory:** about 250 MB is in use while serving 3 small and medium repositories, so 0.5 GB works for a few repositories. Large codebases need more RAM and disk: give the service 1-2 GB, and the heaps grow with it. The first index of a big repository can take many minutes, and the UI is usable while it runs.

**Not included:** upstream's `/reindex` trigger endpoint and its Perforce, Subversion and Mercurial mirroring. This template syncs Git only.

**Updates:** the service builds from the GitHub repo above, which pins the official image by version and digest. When a new OpenGrok release is tested and merged, Railway shows an "update available" notice on your project, and you choose when to apply it. Read `CHANGELOG.md` in the repo first. If the index format changes, the service removes the old index and rebuilds it from the clones on the volume.

## Why Deploy OpenGrok on Railway?

<!-- Recommended: Keep this section as shown below -->
Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying OpenGrok on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
<!-- End recommended section -->

## Variables

| Variable | Default | What it does |
|---|---|---|
| `PORT` | `8000` | Port Caddy listens on; the Railway domain points here (not 8080, which Tomcat uses internally) |
| `OPENGROK_USERNAME` | `admin` | Basic-auth username for the web UI |
| `OPENGROK_PASSWORD` | generated (`${{secret(24,...)}}`) | Basic-auth password for the web UI, at least 12 characters |
| `OPENGROK_REPOS` | `https://github.com/redis/hiredis.git` | Git URLs to index, separated by commas, spaces or new lines; `name=URL` sets the project name |

Optional, read at every start: `SYNC_PERIOD_MINUTES` (30), `INDEXER_OPT` (extra indexer flags), `OPENGROK_THREADS`, `OPENGROK_INDEXER_RAMBUF_MB`, `INDEXER_JAVA_OPTS` and `OPENGROK_WEB_JAVA_OPTS` (by default sized from the service's limits).

## Repo layout

* `Dockerfile`: `FROM opengrok/docker:1.14.21@sha256:f60db434…`, plus Caddy 2.11.9 (copied from the official `caddy` image, pinned by digest) and the wrapper files. Tomcat is bound to 127.0.0.1, and the web app is unpacked at build time.
* `railway-start.sh`: sizes the Java heaps from the service's limits and writes the base configuration with an internal API token. It starts Caddy (basic auth, open `/healthz`), Tomcat and the sync loop, and exits 1 if any of them stops, so Railway restarts the service.
* `railway-sync.sh`: clones, pulls and removes repositories to match `OPENGROK_REPOS`, then runs the OpenGrok indexer, which pushes the new configuration to the web app.
* `gitconfig`: keeps `git clone` inside a small memory limit.

This template replaces upstream's Python start program (`/scripts/start.py`) with these two shell scripts. Upstream's program runs a multiprocessing sync pool next to two JVMs, and it was killed for lack of memory at 0.5 GB.

Upstream OpenGrok is CDDL-1.0, © Oracle and/or its affiliates. This wrapper is MIT.
