# Uninstall

Use ZCode's normal Plugin UI to disable or uninstall `webgpt-zcode-bridge` and remove the Marketplace source when desired.

Dynamic PoC evidence on macOS, Linux and Windows showed that ZCode may retain unreferenced cache directories after uninstall/Marketplace removal even when registry/config state contains no Plugin reference.

Residual cache is not equivalent to an installed Plugin.

Normal uninstall does **not** require manually deleting ZCode internal cache. Any optional cache cleanup must be a separate maintenance action after proving exact ownership and zero live references.

Uninstalling the Plugin does not grant permission to delete a separately retained migration rollback archive.
