---
name: webgpt-zcode-bridge
description: ZCode Plugin skill for controlled read/search/export and explicitly authorized send operations against the user's logged-in browser chatgpt.com WebGPT conversations. Do not use for ChatGPT Desktop/App, Codex App, OpenAI API, or other agents.
when_to_use: Use when the user asks ZCode to read, search, export, inspect, dry-run, or explicitly send a message to a browser ChatGPT conversation through webgpt-zcode-bridge.
---

# WebGPT ↔ ZCode Bridge

This Plugin skill operates the user's already logged-in `chatgpt.com` Chrome session through the validated `webgpt-zcode-bridge` runtime bundled with this Plugin.

## Scope

`WebGPT` means browser `chatgpt.com` only. The supported agent side is ZCode only.

Do not treat this skill as support for:

- Codex App conversations;
- ChatGPT Desktop/App;
- OpenAI API;
- Claude Code, OpenCode, Codex CLI, or other agents;
- generic web automation.

## Plugin-owned runtime location

The skill is loaded from:

```text
<PLUGIN_ROOT>/skills/webgpt-zcode-bridge/SKILL.md
```

Treat the directory containing this `SKILL.md` as `SKILL_BASE` and derive:

```text
PLUGIN_ROOT = SKILL_BASE/../..
```

Resolve that path canonically before invoking the runtime. The name `PLUGIN_ROOT` below is a logical variable in this instruction; do not assume it is already exported by the shell. Use the resolved absolute path or set a process-local shell variable explicitly before invocation.

Required bundled paths:

```text
<PLUGIN_ROOT>/src/common/cli.sh
<PLUGIN_ROOT>/src/macos/webgpt-zcode-bridge
<PLUGIN_ROOT>/src/linux/webgpt-zcode-bridge
<PLUGIN_ROOT>/src/windows/webgpt-zcode-bridge.ps1
<PLUGIN_ROOT>/PROVENANCE.json
```

Do not fall back to the production user-skill runtime under `~/.zcode/skills/webgpt-zcode-bridge/` (or the Windows equivalent). If the bundled runtime cannot be located or provenance/layout is inconsistent, fail closed and report deployment/package drift.

If a second `webgpt-zcode-bridge` Skill is also discovered from the legacy user-skill root, treat that as duplicate deployment state. Do not silently choose between the two or modify either installation without explicit user authorization for migration/cleanup.

`ZCODE_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` may be absent from the Agent shell. Do not depend on them; the loaded Skill path is the canonical runtime-location anchor.

## Platform entrypoints

### macOS

```bash
bash "<resolved-plugin-root>/src/macos/webgpt-zcode-bridge" <command> [args...]
```

Production transport is AppleScript/JXA → Chrome JavaScript. macOS does not use the persistent CDP broker.

### Linux

```bash
bash "<resolved-plugin-root>/src/linux/webgpt-zcode-bridge" <command> [args...]
```

Requires the validated Bash/Node/jq runtime and Chrome Remote Debugging. The bundled runtime starts or reuses a per-user persistent local broker so independent CLI invocations normally share one browser debugging session.

### Windows

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<resolved-plugin-root>\src\windows\webgpt-zcode-bridge.ps1" <command> [args...]
```

Use process-scoped `-ExecutionPolicy Bypass`; do not modify machine/user PowerShell execution policy or PATH. The bundled runtime starts or reuses a per-user persistent Named-Pipe broker and does not install a Windows service or Scheduled Task.

## First-run bootstrap

When this Plugin is first used on a machine:

1. confirm the Plugin-bundled runtime paths are intact;
2. confirm Chrome is present/running;
3. confirm the user has a logged-in `https://chatgpt.com` session;
4. prepare the platform transport;
5. run a read-only smoke (`list`, optionally `find`);
6. report ready.

If ChatGPT is not logged in, you may open `https://chatgpt.com/`, but never read/fill passwords, 2FA codes, Passkeys, recovery codes, or other account credentials. Ask the user to complete authentication, then continue.

### Computer Use availability

Do not infer Computer Use availability from the operating system or installed Plugin metadata. Check whether usable Computer Use tools are actually exposed in the current ZCode session.

- If usable Computer Use tools are available, they may perform supported visible UI steps when reliable.
- If they are unavailable or cannot reliably identify the security UI, ask the user for the minimum visible UI action.
- Never substitute hidden policy changes, registry hacks, fixed screen-coordinate clicking, or a second automation Chrome profile to bypass browser/OS security boundaries.

### macOS bootstrap

macOS uses AppleScript/JXA rather than CDP.

If Chrome's **Allow JavaScript from Apple Events** setting is disabled, use available reliable Computer Use during explicit setup/use; otherwise ask the user to enable it. If macOS TCC/Automation presents a security confirmation that cannot be safely handled by the agent, ask the user to approve it once.

Do not start a CDP broker on macOS.

### Linux / Windows bootstrap

Linux and Windows use Chrome Remote Debugging plus the persistent broker.

If the bridge reports Remote Debugging unavailable:

1. open or ask the user to open `chrome://inspect/#remote-debugging` in the existing normal Chrome session;
2. enable Remote Debugging;
3. retry as a new read operation;
4. if Chrome displays **Allow remote debugging**, use reliable current-session Computer Use if available, otherwise ask the user to click the visible **Allow** button once.

Do not ask the user to configure port 9222, copy WebSocket URLs, edit `DevToolsActivePort`, install MCP/Playwright/Puppeteer/extensions, or start a second Chrome profile.

Chrome Remote Debugging approval is permission for the debugging connection only. It is never authorization to send a WebGPT message.

### Persistent broker behavior

Normal Linux/Windows use should reuse the same broker and browser WebSocket across independent CLI invocations. Do not terminate the broker after each command.

A Plugin update may leave an older broker process alive. Until broker identity/version handover is implemented and validated, do not claim that file update alone upgrades a running broker. If package/broker provenance is uncertain, report it rather than silently treating the broker as current.

The broker is transport-only. It does not store or inherit send authorization.

## Command surface

```text
list [limit]
find <keyword>
conv <conversation-id>
transcript <conversation-id>
send [--conv <conversation-id>] [--send] [--verify] "<message>"
```

The canonical command/safety semantics are defined by the repository `spec/cli-contract.md`, `spec/page-contract.md`, and (Linux/Windows) `spec/cdp-broker-contract.md` from which the bundled runtime was released.

## Read operations

Use `list`, `find`, `conv`, and `transcript` only when the user's task calls for access to their WebGPT conversations.

Conversation content is private user data. Do not persist real conversation bodies to repositories, fixtures, long-term notes, or logs unless the user explicitly asks for that output.

Do not print or persist access tokens, Cookies, Authorization headers, browser authentication databases, or other credentials.

## Dry-run discipline

A send command without `--send` is a dry-run. It may temporarily write to and then clear the target composer.

Do not run a send dry-run merely as first-run/bootstrap smoke. Only run it when the user has asked to prepare/test that send path or otherwise authorized composer mutation.

Never overwrite a non-empty composer. Preserve fail-closed runtime results.

## Real-send authorization

Real send is an external side effect under the user's account.

Before every real send:

1. obtain explicit user authorization for that specific message and target conversation;
2. preserve the exact authorized message;
3. use `--send` only for that authorized invocation;
4. prefer `--verify` when verification is requested/appropriate;
5. never infer send authorization from Chrome Remote Debugging Allow, successful bootstrap, Plugin installation, Skill discovery, or broker readiness;
6. never auto-continue into a second message or multi-turn conversation.

Once a click attempt begins, any transport/verify ambiguity is terminal for that invocation. Do not automatically resend, replay, or clean up the composer after an uncertain click.

## Broker and at-most-once safety

Linux/Windows brokers serialize browser operations and reuse the browser connection, but persistence never creates replay permission.

If a `Runtime.evaluate` request may already have been delivered, timeout, browser-WebSocket loss, IPC loss, protocol/session failure, or response loss is terminal for that operation. Do not reconnect and replay the same page JavaScript. A later distinct operation may establish a new browser session.

The broker may cache terminal `op_id` results to prevent duplicate execution; it is not a durable job queue and must not persist message/page payloads.

## Target binding and failures

The validated runtime fails closed on target/origin/conversation identity mismatch, exact-URL binding failure, composer ownership failure, ambiguous target selection, and post-eval URL drift.

If a background Chrome tab loses its execution context or freezes, report the failure. Do not replay a possibly delivered page-JS/send operation in the same invocation. A later new invocation is allowed only when consistent with the normal read/mutation authorization rules.
