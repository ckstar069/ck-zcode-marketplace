# Update

ZCode compares the Marketplace entry version with the installed Plugin's `.zcode-plugin/plugin.json` version.

For every release:

```text
marketplace.json plugins[].version
==
plugins/webgpt-zcode-bridge/.zcode-plugin/plugin.json version
```

## Persistent broker boundary

Linux and Windows use persistent brokers. Updating Plugin files does not by itself prove that a running old broker has been replaced.

General update support is **not yet promoted**. A broker identity/version handshake and controlled handover must be implemented and dynamically accepted before normal in-place Plugin updates are declared stable.

Do not replay an already-dispatched business operation during broker handover.
