#!/bin/bash
# setup-user-env.sh — Recreate user environment after Arch/KDE reinstall.
#
# This script runs as the normal user. It:
#   1. Ensures ~/Projects and ~/Desktop exist.
#   2. Clones /Projects/ repos from GitHub.
#   3. Clones Desktop folder repos from GitHub.
#   4. Creates Desktop shortcuts for Projects and individual files.
#
# Usage:
#   ./setup-user-env.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

PROJECTS_DIR="$HOME/Projects"
DESKTOP_DIR="$HOME/Desktop"
OS_TOOLKIT_DIR="$PROJECTS_DIR/OS-Toolkit"

PROJECTS_MANIFEST="$OS_TOOLKIT_DIR/projects-repos-manifest.txt"
DESKTOP_MANIFEST="$OS_TOOLKIT_DIR/desktop-repos-manifest.txt"
FILE_MANIFEST="$OS_TOOLKIT_DIR/file-shortcuts-manifest.txt"

# Exclusions (can be overridden by env)
EXCLUDE_CV_FOLDER="${EXCLUDE_CV_FOLDER:-false}"
EXCLUDE_CV_PROJECT="${EXCLUDE_CV_PROJECT:-true}"

is_excluded_project() {
    local folder="$1"
    if [ "$EXCLUDE_CV_PROJECT" = "true" ] && [[ "$folder" == "CV Project" ]]; then
        return 0
    fi
    return 1
}

is_excluded_desktop_folder() {
    local folder="$1"
    if [ "$EXCLUDE_CV_FOLDER" = "true" ] && [[ "$folder" == "CV" ]]; then
        return 0
    fi
    return 1
}

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1"; }

die() { log_err "$1"; exit 1; }

clone_or_update() {
    local url="$1"
    local dest="$2"
    local name
    name=$(basename "$dest")

    # Inject GH_TOKEN into HTTPS URLs for private repos
    if [ -n "${GH_TOKEN:-}" ]; then
        url="${url/https:\/\/github.com\//https:\/\/${GH_TOKEN}@github.com\/}"
    fi

    if [ -d "$dest/.git" ]; then
        log_info "Pulling $name ..."
        if [ "$DRY_RUN" = false ]; then
            git -C "$dest" pull --ff-only
        fi
    else
        log_info "Cloning $name ..."
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$dest"
            # Try main first, then fall back to master if repo default is master
            if ! git clone "$url" "$dest" 2>/dev/null; then
                die "Failed to clone $url into $dest"
            fi
        fi
    fi
}

create_folder_shortcut() {
    local name="$1"
    local target="$2"
    local icon="${3:-folder}"
    local output="$DESKTOP_DIR/$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]._+-').desktop"

    log_info "Creating Desktop shortcut: $name -> $target"
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: would write $output"
        return
    fi

    mkdir -p "$DESKTOP_DIR"
    cat > "$output" <<EOF
[Desktop Entry]
Icon=$icon
Name=$name
Type=Link
URL[\$e]=file:$target
EOF
    chmod +x "$output"
}

create_file_shortcut() {
    local name="$1"
    local target="$2"
    local icon="${3:-accessories-text-editor}"
    local output="$DESKTOP_DIR/$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]._+-').desktop"

    log_info "Creating Desktop file shortcut: $name -> $target"
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: would write $output"
        return
    fi

    mkdir -p "$DESKTOP_DIR"
    cat > "$output" <<EOF
[Desktop Entry]
Icon=$icon
Name=$name
Type=Link
URL[\$e]=file:$target
EOF
    chmod +x "$output"
}

setup_projects() {
    log_info "Setting up /Projects/ repos ..."
    if [ ! -f "$PROJECTS_MANIFEST" ]; then
        log_warn "Projects manifest not found: $PROJECTS_MANIFEST"
        log_warn "Skipping Projects setup."
        return
    fi

    mkdir -p "$PROJECTS_DIR"

    local line folder url shortcut icon subpath dest
    while IFS=$'\t' read -r folder url shortcut icon subpath; do
        # Skip comments and blank lines
        [[ "$folder" =~ ^# ]] && continue
        [ -z "$folder" ] && continue

        if is_excluded_project "$folder"; then
            log_info "Skipping excluded project: $folder"
            continue
        fi

        dest="$PROJECTS_DIR/$folder"
        clone_or_update "$url" "$dest"

        if [ -n "$subpath" ]; then
            create_folder_shortcut "$shortcut" "$dest/$subpath" "$icon"
        else
            create_folder_shortcut "$shortcut" "$dest" "$icon"
        fi
    done < "$PROJECTS_MANIFEST"
}

setup_desktop_folders() {
    log_info "Setting up Desktop folder repos ..."
    if [ ! -f "$DESKTOP_MANIFEST" ]; then
        log_warn "Desktop manifest not found: $DESKTOP_MANIFEST"
        log_warn "Skipping Desktop folders setup."
        return
    fi

    mkdir -p "$DESKTOP_DIR"

    local line folder url repo_name
    while IFS=$'\t' read -r folder repo_name url; do
        [[ "$folder" =~ ^# ]] && continue
        [ -z "$folder" ] && continue

        if is_excluded_desktop_folder "$folder"; then
            log_info "Skipping excluded Desktop folder: $folder"
            continue
        fi

        local dest="$DESKTOP_DIR/$folder"
        clone_or_update "$url" "$dest"
    done < "$DESKTOP_MANIFEST"
}

setup_file_shortcuts() {
    log_info "Setting up file shortcuts ..."
    if [ ! -f "$FILE_MANIFEST" ]; then
        log_warn "File shortcuts manifest not found: $FILE_MANIFEST"
        return
    fi

    local line name target icon
    while IFS=$'\t' read -r name target icon; do
        [[ "$name" =~ ^# ]] && continue
        [ -z "$name" ] && continue

        # Expand $HOME in target
        target="${target/\$HOME/$HOME}"
        create_file_shortcut "$name" "$target" "$icon"
    done < "$FILE_MANIFEST"
}

main() {
    echo "========================================"
    echo " User Environment Setup"
    echo "========================================"
    echo

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN mode — no changes will be made."
        echo
    fi

    if [ ! -d "$OS_TOOLKIT_DIR/.git" ]; then
        log_info "OS-Toolkit not present; cloning it first so manifests are available."
        clone_or_update "https://github.com/topemalheiro/OS-Toolkit.git" "$OS_TOOLKIT_DIR"
    fi

    setup_projects
    setup_desktop_folders
    setup_file_shortcuts

    echo
    log_info "Done."
}

main "$@"
