# Changelog

## 1.14.21-railway.1 (2026-11-24)

First release.

- OpenGrok 1.14.21 (`opengrok/docker:1.14.21@sha256:f60db43496bff95767c2149b544e5f2f9d4815281e7d5ed189a5390b0790b3a8`).
- Caddy 2.11.9 (`caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0`) for basic auth in front of the web UI.
- Git repositories from `OPENGROK_REPOS`, synced and reindexed every `SYNC_PERIOD_MINUTES` (30).
- Fits a 0.5 GB / 1 vCPU Railway service.
