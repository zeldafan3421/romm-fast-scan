# Documentation Summary & Gaps

**Retired.** This was a meta-doc listing what other docs existed, written early in this project's life and already stale by the time the plugin system replaced the original single C-extension design — a list of "what documentation exists" is exactly the kind of file that goes stale fastest and adds the least value once a project has a handful of stable docs.

For an up-to-date map of this repo, see:
- **`README.md`** — user-facing install/usage/configuration guide (source of truth for behavior)
- **`CLAUDE.md`** — developer-facing conventions, architecture, versioning model, and the "Roadmap: incremental backend replacement" section describing where this project is headed
- **`plugins/README.md`** — plugin authoring guide, including signing and the precompiled/third-party plugin path
- The rest of `docs/` — deeper technical dives (`ARCHITECTURE.md`), operational guides (`TESTING.md`, `TROUBLESHOOTING.md`, `PRE_DEPLOYMENT_CHECKLIST.md`, `EDGE_CASES.md`), and build references (`BUILD_QUICK_START.md`, `CONTAINER_BUILD.md`)

If `README.md`/`CLAUDE.md`/`plugins/README.md` ever conflict with something in `docs/`, treat the former as authoritative — this convention is documented in `CLAUDE.md`'s "Repository layout" section.
