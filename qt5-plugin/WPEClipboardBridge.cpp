/*
 * Copyright (C) 2026 Atlantic Browser contributors
 *
 * SPDX-License-Identifier: MPL-2.0
 */

#include "WPEClipboardBridge.h"

#include <QClipboard>
#include <QDebug>
#include <QGuiApplication>
#include <QString>

// Defined in libWPEWebKit — see patches/webkit/webkit-clipboard-qt-hook.patch.
// Passing nullptr restores the stock in-memory behavior.
extern "C" void wpe_qt_set_clipboard_write_hook(void (*fn)(const char*));

namespace {

// Invoked by WebKit on the UI/GUI thread when a page writes plain text to the
// clipboard. QClipboard must be touched on the GUI thread, which is exactly
// where the pasteboard-proxy IPC is dispatched.
void writeTextToSystemClipboard(const char* utf8Text)
{
    if (!utf8Text)
        return;
    if (QClipboard* clipboard = QGuiApplication::clipboard())
        clipboard->setText(QString::fromUtf8(utf8Text));
}

} // namespace

void WPEClipboardBridge::ensure()
{
    static bool registered = false;
    if (registered)
        return;
    registered = true;

    if (qEnvironmentVariableIntValue("ATLANTIC_DISABLE_CLIPBOARD_BRIDGE") == 1) {
        qDebug() << "[WPE-CLIP] system clipboard bridge disabled via env";
        return;
    }

    wpe_qt_set_clipboard_write_hook(&writeTextToSystemClipboard);
    qDebug() << "[WPE-CLIP] web clipboard writes bridged to QClipboard";
}
