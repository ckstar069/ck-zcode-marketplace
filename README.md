# CK ZCode Marketplace

Public ZCode Plugin distribution repository for CK-maintained capabilities.

## Current release candidate

`webgpt-zcode-bridge 0.1.0-rc.1`

This repository is a **distribution surface**, not the canonical implementation source. The canonical source, contracts, tests, architecture, and release tooling live in the private `ckstar069/ck-ai-kit` repository.

The release candidate is being validated through ZCode's real remote Marketplace installation flow before it is promoted as the primary installation path.

## Install

In ZCode:

```text
Settings
→ Plugins
→ Create
→ Add Plugin Marketplace
→ ckstar069/ck-zcode-marketplace
```

Then install `webgpt-zcode-bridge` and open a fresh ZCode session.

See:

- [Install](docs/INSTALL.md)
- [Update](docs/UPDATE.md)
- [Migration](docs/MIGRATION.md)
- [Uninstall](docs/UNINSTALL.md)

## Scope

`webgpt-zcode-bridge` supports:

```text
ZCode ↔ browser chatgpt.com WebGPT
```

It does not imply support for ChatGPT Desktop/App, Codex App, OpenAI API, Claude Code, OpenCode, or other agents.

A Plugin installation or Chrome Remote Debugging approval never authorizes sending a ChatGPT message. Every real send still requires explicit authorization for the exact target conversation and exact message.

## Provenance

Every released Plugin package contains `PROVENANCE.json` and `RUNTIME_MANIFEST.json` linking the public distribution artifact back to the exact canonical `ck-ai-kit` source commit and runtime Git tree.

No credentials, cookies, access tokens, Authorization headers, browser authentication databases, or private conversation bodies belong in this repository.
