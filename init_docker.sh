#!/bin/bash

handle_exit() {
    EXIT_CODE=$?
    # Random delay between 1-5 minutes, spread between 30 seconds
    MIN_DELAY=30
    MAX_DELAY=300
    ACTUAL_DELAY=$((MIN_DELAY + RANDOM % (MAX_DELAY - MIN_DELAY + 1)))

    echo "Container exited with code $EXIT_CODE. Restarting in $ACTUAL_DELAY seconds..."
    sleep $ACTUAL_DELAY
    exit 1
}

# Clone a repo at branch (shallow), then optionally detach to an exact commit object.
# $1: label for logs  $2: destination path  $3: git URL  $4: branch name  $5: optional commit (SHA/tag)
clone_repo_with_optional_pin() {
    local label="$1"
    local dest="$2"
    local repo_url="$3"
    local branch="$4"
    local commit="${5:-}"

    echo "📦 Cloning ${label}..."
    rm -rf "${dest}"
    if ! git clone --depth 1 --branch "${branch}" "${repo_url}" "${dest}"; then
        echo "❌ git clone failed for ${label}"
        return 1
    fi

    if [ -z "${commit}" ]; then
        echo "ℹ️  ${label}: no commit pin (SNAPSHOT_*_COMMIT unset or empty) — using shallow branch tip"
        return 0
    fi

    (
        cd "${dest}" || exit 1
        if ! git fetch --depth 1 origin "${commit}"; then
            echo "❌ git fetch failed for ${label} (commit=${commit})"
            exit 1
        fi
        if ! git reset --hard "${commit}"; then
            echo "❌ git reset --hard failed for ${label} (commit=${commit})"
            exit 1
        fi
    ) || return 1

    echo "✅ ${label} pinned to ${commit}"
    return 0
}

# Always run bootstrap
echo "🚀 Running bootstrap..."

clone_repo_with_optional_pin \
    "config repo" \
    "/app/config" \
    "${SNAPSHOT_CONFIG_REPO}" \
    "${SNAPSHOT_CONFIG_REPO_BRANCH}" \
    "${SNAPSHOT_CONFIG_REPO_COMMIT:-}" \
    || {
        echo "❌ Bootstrap failed (config repo)"
        exit 1
    }

clone_repo_with_optional_pin \
    "compute repo" \
    "/app/computes" \
    "${SNAPSHOTTER_COMPUTE_REPO}" \
    "${SNAPSHOTTER_COMPUTE_REPO_BRANCH}" \
    "${SNAPSHOTTER_COMPUTE_REPO_COMMIT:-}" \
    || {
        echo "❌ Bootstrap failed (compute repo)"
        exit 1
    }

# Run autofill to setup config files
bash snapshotter_autofill.sh
if [ $? -ne 0 ]; then
    echo "❌ Config setup failed"
    exit 1
fi

# Print the version of the snapshotter
poetry run python -m snapshotter.version

# Continue with existing steps
poetry run python -m snapshotter.snapshotter_id_ping
ret_status=$?

if [ $ret_status -ne 0 ]; then
    exit 1
fi

# Set up traps for all possible exit scenarios
trap 'handle_exit' EXIT HUP INT QUIT ABRT TERM KILL

poetry run python -m snapshotter.system_event_detector
