/*
 * Copyright (C) 2026 Atlantic Browser contributors
 *
 * SPDX-License-Identifier: MPL-2.0
 */

#pragma once

// Bridges WebKit's libwpe pasteboard writes to the host Qt system clipboard.
// In this WPEBackend-fdo build the libwpe pasteboard singleton is an in-process
// std::map stub (fdo exports no _wpe_pasteboard_interface), so a page's
// navigator.clipboard.writeText() / document.execCommand('copy') resolves but
// never reaches the SFOS system clipboard. WebKit's PlatformPasteboardLibWPE
// (which runs here in the UI process = a QGuiApplication) exposes a write hook;
// this registers a QClipboard-backed implementation.
class WPEClipboardBridge {
public:
    // Register the write hook with WebKit. Idempotent and process-global — the
    // hook is a single WebCore function pointer, so extra calls are no-ops.
    // Skipped when ATLANTIC_DISABLE_CLIPBOARD_BRIDGE=1 (leaves stock behavior).
    static void ensure();
};
