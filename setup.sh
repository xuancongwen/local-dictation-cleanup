#!/bin/sh
# Set up the local-dictation-cleanup model under llama-server and point voxtype
# at it.
#
# Usage: ./setup.sh [--profile NAME] [--model-only]
#
#   --profile NAME  Which profile in profiles/ to run: "max" (Qwen3.5-4B,
#                   3.0 GB while loaded), "standard" (Qwen3.5-2B, 1.5 GB), or
#                   "tiny" (Qwen2.5-0.5B, 0.6 GB). Defaults to standard on
#                   macOS and max everywhere else.
#   --model-only    Download the model, render the prompts, and start the
#                   server, but do not touch voxtype. Implied on macOS, where
#                   voxtype does not run.
#
# Steps: download the profile's GGUF into models/ (verifying its sha256),
# render prompts/<profile>.json, record the profile in .active-profile for
# wrapper.sh, install and start a "local-dictation-cleanup" systemd user
# service running llama-server with that model, smoke-test it, add an
# [output.post_process] block to the voxtype config, and restart voxtype.
#
# Assumes llama.cpp (llama-server) and voxtype 1.0 or newer are installed. It
# checks for both and stops with a message if either is missing. It never
# installs packages and never overwrites an existing post_process block.
# Switching profiles is re-running it with another --profile.

set -eu

SERVICE=local-dictation-cleanup
PORT=8189
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

info() { printf '==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# sha256 of a file, using whichever tool the platform has.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else echo ""; fi
}

# fetch_gguf URL DEST SHA256: download DEST if it is missing or its checksum
# is wrong. Resumes a partial download. An empty SHA256 skips verification.
fetch_gguf() {
    url=$1; dest=$2; want=$3
    if [ -f "$dest" ] && { [ -z "$want" ] || [ "$(sha256_of "$dest")" = "$want" ]; }; then
        info "Model weights already present at $dest"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    info "Downloading model weights from $url"
    info "One-time download of a few GB into $(dirname "$dest")"
    curl -L --fail --progress-bar -C - -o "$dest" "$url" || die "download failed"
    if [ -n "$want" ]; then
        have=$(sha256_of "$dest")
        if [ -z "$have" ]; then
            info "No sha256 tool found; skipping checksum verification"
        elif [ "$have" != "$want" ]; then
            rm -f "$dest"
            die "checksum mismatch for $dest (got $have, want $want); file removed, re-run to retry"
        fi
    fi
}

# --- Arguments --------------------------------------------------------------

OS=$(uname -s 2>/dev/null || echo unknown)
PROFILE=""
MODEL_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)   [ $# -ge 2 ] || die "--profile needs a name"; PROFILE=$2; shift 2 ;;
        --profile=*) PROFILE=${1#--profile=}; shift ;;
        --model-only) MODEL_ONLY=1; shift ;;
        -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "unknown argument $1 (see --help)" ;;
    esac
done

if [ -z "$PROFILE" ]; then
    case "$OS" in Darwin) PROFILE=standard ;; *) PROFILE=max ;; esac
fi
case "$OS" in Darwin) MODEL_ONLY=1 ;; esac

PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE"
[ -f "$PROFILE_FILE" ] || die "no profile named '$PROFILE' in $SCRIPT_DIR/profiles (have: $(ls "$SCRIPT_DIR/profiles" | tr '\n' ' '))"
GGUF_URL=; GGUF_SHA256=
. "$PROFILE_FILE"
[ -n "$GGUF_URL" ] || die "profiles/$PROFILE has no GGUF_URL"
GGUF="$SCRIPT_DIR/models/$(basename "$GGUF_URL")"

# --- Preflight checks -------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl is not installed"
LLAMA_SERVER=$(command -v llama-server 2>/dev/null) \
    || die "llama-server is not installed. On Arch: pacman -S llama-cpp ggml-cuda (or ggml-vulkan). Elsewhere: https://github.com/ggml-org/llama.cpp"

if [ "$MODEL_ONLY" -eq 0 ]; then
    command -v voxtype >/dev/null 2>&1 \
        || die "voxtype is not installed. See https://github.com/peteonrails/voxtype (or pass --model-only)"

    VOXTYPE_VERSION=$(voxtype --version 2>/dev/null | awk '{print $NF}')
    VOXTYPE_MAJOR=${VOXTYPE_VERSION%%.*}
    case "$VOXTYPE_MAJOR" in
        ''|*[!0-9]*) die "could not parse voxtype version from '$VOXTYPE_VERSION'" ;;
    esac
    [ "$VOXTYPE_MAJOR" -ge 1 ] \
        || die "voxtype $VOXTYPE_VERSION is too old; post-processing needs 1.0 or newer"

    [ -f "$CONFIG" ] \
        || die "no voxtype config at $CONFIG. Run 'voxtype' once to generate the default config, then re-run this script."
fi

# --- Model and prompt -------------------------------------------------------

fetch_gguf "$GGUF_URL" "$GGUF" "$GGUF_SHA256"

info "Rendering prompts/ from system prompts, examples, and profiles/"
"$SCRIPT_DIR/gen-prompts.sh" >/dev/null
printf '%s\n' "$PROFILE" > "$SCRIPT_DIR/.active-profile"

# --- Server -----------------------------------------------------------------

# -ub 64 matters for the Qwen3.5 profiles: llama-server can only resume their
# hybrid-attention state from a checkpoint it takes one micro-batch before the
# end of the prompt, so a small micro-batch means only the new dictation and a
# few dozen tokens are evaluated per request instead of hundreds.
SERVER_CMD="$LLAMA_SERVER -m $GGUF -ngl 99 -c 4096 -np 1 -ub 64 --host 127.0.0.1 --port $PORT"

if [ "$OS" = Darwin ] || ! command -v systemctl >/dev/null 2>&1; then
    info "No systemd here, so start the server yourself and keep it running:"
    printf '    %s\n' "$SERVER_CMD"
    info "Then pipe text through: echo 'some text' | $SCRIPT_DIR/wrapper.sh"
    exit 0
fi

mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/$SERVICE.service" <<EOT
# Written by $SCRIPT_DIR/setup.sh (profile: $PROFILE). Re-run it to change.
[Unit]
Description=local-dictation-cleanup model server (llama-server, profile $PROFILE)

[Service]
ExecStart=$SERVER_CMD
Restart=on-failure

[Install]
WantedBy=default.target
EOT
info "Starting the $SERVICE user service (profile: $PROFILE)"
systemctl --user daemon-reload
systemctl --user enable "$SERVICE" >/dev/null 2>&1
systemctl --user restart "$SERVICE"

info "Waiting for the model to load"
i=0
until curl -s "http://127.0.0.1:$PORT/health" | grep -q '"ok"'; do
    i=$((i + 1))
    [ "$i" -le 120 ] || die "llama-server did not come up; see: journalctl --user -u $SERVICE"
    sleep 1
done

info "Smoke test"
SAMPLE="um so let's meet tuesday no wait wednesday at four"
RESULT=$(printf '%s\n' "$SAMPLE" | "$SCRIPT_DIR/wrapper.sh")
printf '    in:  %s\n    out: %s\n' "$SAMPLE" "$RESULT"
[ -n "$RESULT" ] || die "model returned no output; see: journalctl --user -u $SERVICE"

if [ "$MODEL_ONLY" -eq 1 ]; then
    info "Model running. Run ./test.sh for the full check, or pipe text through: echo 'some text' | $SCRIPT_DIR/wrapper.sh"
    exit 0
fi

# --- Configure voxtype ------------------------------------------------------

if grep -Eq '^[[:space:]]*\[output\.post_process\]' "$CONFIG"; then
    info "$CONFIG already has a [output.post_process] section; leaving it alone:"
    awk '/^[[:space:]]*\[output\.post_process\]/ { p = 1; print; next }
         p && /^[[:space:]]*\[/ { exit }
         p { print }' "$CONFIG" | sed 's/^/    /'
    printf '    Edit it by hand if you want it to use: command = "%s/wrapper.sh"\n' "$SCRIPT_DIR"
    # Earlier versions of this project ran the model through Ollama.
    if awk '/^[[:space:]]*\[output\.post_process\]/ { p = 1; next } p && /^[[:space:]]*\[/ { exit }
            p && /ollama run/ { found = 1 } END { exit !found }' "$CONFIG"; then
        info "That block still runs the model through Ollama, which this project no longer uses."
        info "Change its command line to the one above. The old Ollama models can then be removed with 'ollama rm'."
    fi
else
    BACKUP="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG" "$BACKUP"
    info "Backed up config to $BACKUP"
    info "Appending [output.post_process] to $CONFIG"
    cat >> "$CONFIG" <<EOT

# Added by local-dictation-cleanup/setup.sh
[output.post_process]
command = "$SCRIPT_DIR/wrapper.sh"
timeout_ms = 30000
trim = true
fallback_on_empty = false
EOT
fi

# --- Restart the daemon -----------------------------------------------------

if systemctl --user is-active --quiet voxtype 2>/dev/null; then
    info "Restarting voxtype user service"
    systemctl --user restart voxtype
elif pgrep -x voxtype >/dev/null 2>&1; then
    info "voxtype is running outside systemd; restart it yourself to pick up the new config"
else
    info "voxtype is not running; start it with 'voxtype daemon' or 'systemctl --user start voxtype'"
fi

info "Done. Press your voxtype hotkey and dictate; cleaned text will be typed at the cursor."
