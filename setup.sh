#!/bin/sh
# Build the voxtype-llm-wrapper model in Ollama and point voxtype at it.
#
# Usage: ./setup.sh [--profile NAME] [--model-only] [BASE_MODEL]
#
#   --profile NAME  Which profile in profiles/ to build: "max" (Qwen3.5-4B,
#                   4.9 GB while loaded), "standard" (Qwen3.5-2B, 2.4 GB), or
#                   "fast" (granite3.3:2b, 2.1 GB, lowest latency).
#                   Defaults to standard on macOS and max everywhere else.
#   --model-only    Build the Ollama model and stop; do not touch voxtype.
#                   Implied on macOS, where voxtype does not run.
#   BASE_MODEL      Override the FROM line of the chosen profile for this run
#                   only (e.g. ./setup.sh gemma3:4b). Any TEMPLATE and stop
#                   tokens in the profile are dropped too, since they belong to
#                   the profile's own base model. Nothing in the repo is
#                   modified.
#
# Assumes Ollama and voxtype (1.0 or newer) are already installed. The script
# checks for both and stops with a message if either is missing. It never
# installs packages and never overwrites an existing post_process block.
#
# A profile whose FROM line is a file path (the max and standard profiles) carries
# "# gguf: URL" and "# sha256: HASH" lines. The script downloads that file into
# models/ next to this script if it is missing or its checksum does not match.

set -eu

MODEL_NAME="voxtype-llm-wrapper"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
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
        info "Base model weights already present at $dest"
        return
    fi
    command -v curl >/dev/null 2>&1 || die "curl is needed to download $url"
    mkdir -p "$(dirname "$dest")"
    info "Downloading base model weights from $url"
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
BASE_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)   [ $# -ge 2 ] || die "--profile needs a name"; PROFILE=$2; shift 2 ;;
        --profile=*) PROFILE=${1#--profile=}; shift ;;
        --model-only) MODEL_ONLY=1; shift ;;
        -h|--help)   sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          die "unknown option $1" ;;
        *)           [ -z "$BASE_OVERRIDE" ] || die "unexpected argument $1"; BASE_OVERRIDE=$1; shift ;;
    esac
done

if [ -z "$PROFILE" ]; then
    case "$OS" in Darwin) PROFILE=standard ;; *) PROFILE=max ;; esac
fi
case "$OS" in Darwin) MODEL_ONLY=1 ;; esac

PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE"
[ -f "$PROFILE_FILE" ] || die "no profile named '$PROFILE' in $SCRIPT_DIR/profiles (have: $(ls "$SCRIPT_DIR/profiles" | tr '\n' ' '))"

# --- Preflight checks -------------------------------------------------------

command -v ollama >/dev/null 2>&1 \
    || die "ollama is not installed. See https://ollama.com/download"

if ! ollama list >/dev/null 2>&1; then
    die "Ollama is installed but not running. Start it with 'ollama serve' (or the Ollama app on macOS), then re-run this script."
fi

if [ "$MODEL_ONLY" -eq 0 ]; then
    command -v voxtype >/dev/null 2>&1 \
        || die "voxtype is not installed. See https://github.com/peteonrails/voxtype (or pass --model-only to build just the model)"

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

# --- Build the model --------------------------------------------------------

info "Rendering Modelfiles from system_prompt.txt, examples.tsv, and profiles/"
"$SCRIPT_DIR/gen-modelfiles.sh" >/dev/null
MODELFILE="$SCRIPT_DIR/Modelfile.$PROFILE"

BASE_MODEL=${BASE_OVERRIDE:-$(awk '/^FROM[[:space:]]/ {print $2; exit}' "$MODELFILE")}
[ -n "$BASE_MODEL" ] || die "could not determine base model from $MODELFILE"

if [ -n "$BASE_OVERRIDE" ]; then
    info "Pulling base model $BASE_MODEL (skips quickly if already present)"
    ollama pull "$BASE_MODEL"
    TMP_MODELFILE=$(mktemp)
    trap 'rm -f "$TMP_MODELFILE"' EXIT
    # Swap the FROM line and drop the profile's TEMPLATE block and stop tokens,
    # which are specific to the profile's own base model.
    awk -v base="$BASE_MODEL" '
        /^FROM[[:space:]]/  { print "FROM " base; next }
        /^PARAMETER stop /  { next }
        /^TEMPLATE """/     { skip = 1; next }
        skip                { if (/"""[[:space:]]*$/) skip = 0; next }
        { print }' "$MODELFILE" > "$TMP_MODELFILE"
    BUILD_FROM="$TMP_MODELFILE"
else
    case "$BASE_MODEL" in
        *.gguf)
            GGUF_URL=$(awk '/^# gguf:/ {print $3; exit}' "$PROFILE_FILE")
            GGUF_SHA=$(awk '/^# sha256:/ {print $3; exit}' "$PROFILE_FILE")
            [ -n "$GGUF_URL" ] || die "profile $PROFILE uses a GGUF file but has no '# gguf: URL' line"
            fetch_gguf "$GGUF_URL" "$SCRIPT_DIR/$BASE_MODEL" "$GGUF_SHA"
            ;;
        *)
            info "Pulling base model $BASE_MODEL (skips quickly if already present)"
            ollama pull "$BASE_MODEL"
            ;;
    esac
    BUILD_FROM="$MODELFILE"
fi

# Unload any resident copy of the previous build first. Ollama keeps a model
# loaded for as long as its keep-alive says, and rebuilding under the same name
# leaves the old runner holding memory with no name pointing at it.
if ollama ps 2>/dev/null | grep -q "^$MODEL_NAME"; then
    info "Unloading the currently loaded $MODEL_NAME"
    ollama stop "$MODEL_NAME" >/dev/null 2>&1 || true
fi

info "Building $MODEL_NAME (profile: $PROFILE, base: $BASE_MODEL)"
ollama create "$MODEL_NAME" -f "$BUILD_FROM"

info "Smoke test"
SAMPLE="um so let's meet tuesday no wait wednesday at four"
RESULT=$(printf '%s\n' "$SAMPLE" | "$SCRIPT_DIR/wrapper.sh" "$MODEL_NAME")
printf '    in:  %s\n    out: %s\n' "$SAMPLE" "$RESULT"
[ -n "$RESULT" ] || die "model returned no output; check 'ollama run $MODEL_NAME' by hand"

if [ "$MODEL_ONLY" -eq 1 ]; then
    info "Model built. Run ./test.sh for the full check, or pipe text through: echo 'some text' | $SCRIPT_DIR/wrapper.sh"
    exit 0
fi

# --- Configure voxtype ------------------------------------------------------

if grep -Eq '^[[:space:]]*\[output\.post_process\]' "$CONFIG"; then
    info "$CONFIG already has a [output.post_process] section; leaving it alone:"
    awk '/^[[:space:]]*\[output\.post_process\]/ { p = 1; print; next }
         p && /^[[:space:]]*\[/ { exit }
         p { print }' "$CONFIG" | sed 's/^/    /'
    printf '    Edit it by hand if you want it to use: command = "%s/wrapper.sh"\n' "$SCRIPT_DIR"
else
    BACKUP="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG" "$BACKUP"
    info "Backed up config to $BACKUP"
    info "Appending [output.post_process] to $CONFIG"
    cat >> "$CONFIG" <<EOT

# Added by voxtype-llm-wrapper/setup.sh
[output.post_process]
command = "$SCRIPT_DIR/wrapper.sh"
timeout_ms = 30000
trim = true
fallback_on_empty = true
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
