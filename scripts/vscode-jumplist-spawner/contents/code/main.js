// VS Code: Jump List Spawner
// Moves VS Code windows to the virtual desktop requested by code-open-folder.

const PENDING_PLACEMENT_FILE = "/home/tope/.config/vscode-jumplist/pending-placement.json";
const PLACEMENT_TIMEOUT_MS = 15000;

function readPendingPlacement() {
    var process = new QProcess();
    process.start("/bin/sh", ["-c", "cat '" + PENDING_PLACEMENT_FILE + "' 2>/dev/null || echo '{}'"]);
    process.waitForFinished(500);
    var output = process.readAllStandardOutput();
    if (!output || output.length === 0) {
        return null;
    }
    try {
        return JSON.parse(output);
    } catch (e) {
        print("VSCode:JumpList: Failed to parse pending placement: " + e);
        return null;
    }
}

function clearPendingPlacement() {
    var process = new QProcess();
    process.start("/bin/rm", ["-f", PENDING_PLACEMENT_FILE]);
    process.waitForFinished(500);
}

function applyPlacement(window) {
    var placement = readPendingPlacement();
    if (!placement) {
        return;
    }

    var timestamp = placement.timestamp || 0;
    var now = Date.now();
    if (now - timestamp > PLACEMENT_TIMEOUT_MS) {
        print("VSCode:JumpList: Pending placement expired");
        clearPendingPlacement();
        return;
    }

    var desktopIndex = placement.desktop;
    if (typeof desktopIndex !== "number" || desktopIndex < 1) {
        print("VSCode:JumpList: No valid desktop in pending placement");
        clearPendingPlacement();
        return;
    }

    var desktops = workspace.desktops;
    if (desktopIndex > desktops.length) {
        print("VSCode:JumpList: Desktop " + desktopIndex + " does not exist (max: " + desktops.length + ")");
        clearPendingPlacement();
        return;
    }

    var targetDesktop = desktops[desktopIndex - 1];
    if (!targetDesktop) {
        print("VSCode:JumpList: Could not resolve desktop " + desktopIndex);
        clearPendingPlacement();
        return;
    }

    print("VSCode:JumpList: Moving window '" + window.caption + "' to desktop " + desktopIndex);
    window.desktops = [targetDesktop];
    clearPendingPlacement();
}

function isVSCodeWindow(window) {
    if (!window) {
        return false;
    }

    var resourceClass = (window.resourceClass || "").toLowerCase();
    var caption = window.caption || "";

    if (resourceClass === "code" || resourceClass === "code:") {
        return true;
    }

    if (caption.indexOf("Visual Studio Code:") !== -1 || caption.indexOf("VS Code:") !== -1) {
        return true;
    }

    return false;
}

workspace.windowAdded.connect(function(window) {
    if (!isVSCodeWindow(window)) {
        return;
    }

    print("VSCode:JumpList: New VS Code window detected: '" + window.caption + "'");

    var timer = new QTimer();
    timer.singleShot = true;
    timer.interval = 500;
    timer.triggered.connect(function() {
        applyPlacement(window);
    });
    timer.start();
});

print("VSCode:JumpList: Spawner script loaded");
