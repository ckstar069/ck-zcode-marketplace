# Install

> Release candidate: `webgpt-zcode-bridge 0.1.0-rc.1`.

## New machine / clean ZCode installation

1. Install ZCode and Google Chrome.
2. Open any ZCode workspace.
3. Open `Settings → Plugins`.
4. Choose `Create → Add Plugin Marketplace`.
5. Add `ckstar069/ck-zcode-marketplace`.
6. Install `webgpt-zcode-bridge`.
7. Open a fresh ZCode session.
8. Ask ZCode for a read-only bridge task such as listing recent WebGPT conversations.

The first use may require normal browser/OS permission steps. Chrome Remote Debugging approval is debugging permission only and never authorizes sending a WebGPT message.

## Existing user-skill installations

Do **not** install this same-name Plugin alongside an existing:

- macOS/Linux: `~/.zcode/skills/webgpt-zcode-bridge/`
- Windows: `%USERPROFILE%\.zcode\skills\webgpt-zcode-bridge\`

That migration requires a controlled cutover to avoid duplicate Skill discovery and broker provenance ambiguity. See [MIGRATION.md](MIGRATION.md).

## Current RC boundary

The Marketplace package is being validated from the real remote GitHub source. The existing user-skill installation remains production until migration/update acceptance is complete.
