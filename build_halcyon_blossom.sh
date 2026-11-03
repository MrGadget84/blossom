#!/usr/bin/env bash
# Halcyon 16.2 / Xiaomi Redmi 9A (blossom)
# Run from the Android source-tree root.
# Source sync is intentionally omitted: Crave Devspaces manage source sync separately.

set -Eeuo pipefail

# Build settings (can be overridden through environment variables).
CONFIG_LUNCH="${CONFIG_LUNCH:-halcyon_blossom-user}"
CONFIG_TARGET="${CONFIG_TARGET:-bacon}"
CONFIG_CLEAN="${CONFIG_CLEAN:-0}"       # 1 = remove out/
CONFIG_JOBS="${CONFIG_JOBS:-$(nproc --all)}"

# Optional Telegram notifications. Put credentials in Crave secrets/environment,
# never directly in this file.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_ERROR_CHAT_ID="${TELEGRAM_ERROR_CHAT_ID:-$TELEGRAM_CHAT_ID}"

# Optional GoFile upload: UPLOAD_GOTOFILE=1
UPLOAD_GOTOFILE="${UPLOAD_GOTOFILE:-0}"

ROOT_DIR="$(pwd)"
DEVICE="blossom"
OUT_DIR="$ROOT_DIR/out/target/product/$DEVICE"
LOG_FILE="$ROOT_DIR/build.log"
BUILD_MESSAGE_ID=""

telegram_enabled() {
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] &&
        command -v curl >/dev/null 2>&1
}

telegram_send() {
    local response
    telegram_enabled || return 0
    response="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1" 2>/dev/null || true)"
    sed -n 's/.*"message_id":\([0-9][0-9]*\).*/\1/p' <<<"$response" | head -n1
}

telegram_edit() {
    local chat_id="$1" message_id="$2" message="$3"
    [[ -n "$message_id" ]] && telegram_enabled || return 0
    curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/editMessageText" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "message_id=${message_id}" \
        --data-urlencode "text=${message}" >/dev/null 2>&1 || true
}

on_error() {
    local code=$?
    trap - ERR
    echo "Build failed (exit ${code}). Check ${LOG_FILE} and out/error.log." >&2
    if [[ -n "$BUILD_MESSAGE_ID" && -n "$TELEGRAM_ERROR_CHAT_ID" ]]; then
        telegram_edit "$TELEGRAM_ERROR_CHAT_ID" "$BUILD_MESSAGE_ID" \
            "Halcyon build failed for ${DEVICE}. Exit code: ${code}. Check build.log / out/error.log."
    fi
    exit "$code"
}
trap on_error ERR

if [[ ! -f build/envsetup.sh ]]; then
    echo "ERROR: Run this script from the Android source-tree root (build/envsetup.sh not found)." >&2
    exit 2
fi

if [[ "$CONFIG_CLEAN" == "1" ]]; then
    echo "Removing out/ ..."
    rm -rf out
fi

rm -f out/error.log out/.lock "$LOG_FILE"
mkdir -p "$OUT_DIR"

BUILD_MESSAGE_ID="$(telegram_send "Starting Halcyon 16.2 build for Xiaomi Redmi 9A (blossom).")"

echo "Lunch:  $CONFIG_LUNCH"
echo "Target: $CONFIG_TARGET"
echo "Jobs:   $CONFIG_JOBS"
echo "Device: $DEVICE"
echo "Source sync is not run by this script."

source build/envsetup.sh
lunch "$CONFIG_LUNCH"

echo "== installclean =="
m installclean -j"$CONFIG_JOBS"

echo "== building $CONFIG_TARGET =="
set +e
m "$CONFIG_TARGET" -j"$CONFIG_JOBS" 2>&1 | tee "$LOG_FILE"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$BUILD_STATUS" -ne 0 ]]; then
    echo "Build command failed with exit code $BUILD_STATUS." >&2
    exit "$BUILD_STATUS"
fi

shopt -s nullglob
zips=("$OUT_DIR"/*"$DEVICE"*.zip)
ZIP_FILE=""
for candidate in "${zips[@]}"; do
    [[ "$candidate" == *ota*.zip ]] && continue
    if [[ -z "$ZIP_FILE" || "$candidate" -nt "$ZIP_FILE" ]]; then
        ZIP_FILE="$candidate"
    fi
done

if [[ -z "$ZIP_FILE" ]]; then
    echo "Build command succeeded, but no non-OTA *${DEVICE}*.zip was found in ${OUT_DIR}."
    echo "Check the output directory; CONFIG_TARGET may need changing for this ROM tree."
    exit 3
fi

MD5="$(md5sum "$ZIP_FILE" | awk '{print $1}')"
SIZE="$(du -h "$ZIP_FILE" | awk '{print $1}')"
echo "BUILD SUCCESS"
echo "ZIP:  $ZIP_FILE"
echo "Size: $SIZE"
echo "MD5:  $MD5"

if [[ "$UPLOAD_GOTOFILE" == "1" ]]; then
    command -v jq >/dev/null 2>&1 || { echo "jq is required for GoFile upload."; exit 4; }
    SERVER="$(curl -fsS https://api.gofile.io/servers | jq -r '.data.servers[0].name')"
    [[ -n "$SERVER" && "$SERVER" != "null" ]] || { echo "Could not get GoFile server."; exit 4; }
    RESPONSE="$(curl -fsS -F "file=@${ZIP_FILE}" "https://${SERVER}.gofile.io/uploadFile")"
