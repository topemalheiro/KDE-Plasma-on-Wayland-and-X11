// Insightful Tray Only
//
// Makes the Insightful (Workpuls) agent behave like Hubstaff: while minimized it
// disappears from the taskbar and pager entirely, leaving only its system tray
// icon. Restoring it puts it back in the taskbar.
//
// Restore path: right-click the tray icon -> "Show Insightful".
// The tray item is an Ayatana/libappindicator menu-only StatusNotifierItem with
// NO Activate method, so left-click opens the menu and cannot raise the window.
// That is the protocol's behaviour, not something a script can change.
//
// skipSwitcher is deliberately NEVER set. With the window gone from the taskbar,
// Alt+Tab is the only fallback if the tray icon ever fails, and setting
// skipSwitcher is exactly what previously left the window unreachable.

function isInsightful(window) {
    if (!window) return false;
    // Match on window class only. The caption is NOT safe to match: a browser
    // tab titled "Insightful | Employees" would match it too.
    var cls = (window.resourceClass || "").toString().toLowerCase();
    var name = (window.resourceName || "").toString().toLowerCase();
    return cls.indexOf("workpuls") >= 0 || name.indexOf("workpuls") >= 0;
}

function syncTaskbarVisibility(window) {
    if (!isInsightful(window)) return;
    var hidden = (window.minimized === true);
    window.skipTaskbar = hidden;
    window.skipPager = hidden;
}

function attach(window) {
    if (!isInsightful(window)) return;

    // Apply current state immediately.
    syncTaskbarVisibility(window);

    // Then follow it.
    if (window.minimizedChanged && typeof window.minimizedChanged.connect === "function") {
        window.minimizedChanged.connect(function () {
            syncTaskbarVisibility(window);
        });
    }
}

workspace.windowAdded.connect(attach);

// Enumerate windows that already exist. The property name differs across KWin
// versions -- KWin 6 exposes stackingOrder; workspace.windows is undefined here
// and throws "Cannot read property 'length' of undefined" if used blindly.
// (The hubstaff-tray-only script has that latent bug; it only works because
// windowAdded is connected before the throw.)
var existing = workspace.stackingOrder || workspace.windows || [];
for (var i = 0; i < existing.length; i++) {
    attach(existing[i]);
}
