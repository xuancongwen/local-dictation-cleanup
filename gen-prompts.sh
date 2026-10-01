#!/bin/sh
# Render one llama-server request per profile from profiles/<name>, its system
# prompt, and its example files.
#
# Usage: ./gen-prompts.sh [OUTPUT_DIR [PROFILE_FILE...]]
#
# Writes OUTPUT_DIR/<name>.json (default prompts/) for every file in profiles/,
# or only for the given profile files (tune.sh passes a temporary one). Prompt
# and example paths in a profile are relative to the repo unless absolute.
#
# Each file is a complete body for llama-server's /completion endpoint whose
# "prompt" holds the system prompt and every example, already in the model's
# chat format, with {{TRANSCRIPT}} where the dictation goes. Replace the placeholder with the
# JSON-escaped transcript followed by \n and POST it; wrapper.sh does exactly
# that, and an app can load the same file. Because every request shares the
# same text up to the placeholder, llama-server reuses its cache for all of it.
#
# The rendered files are committed. Run this after editing a system prompt,
# an examples file, or anything in profiles/; setup.sh runs it too.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${1:-$SCRIPT_DIR/prompts}
[ $# -gt 0 ] && shift
[ $# -gt 0 ] || set -- "$SCRIPT_DIR"/profiles/*
mkdir -p "$OUT_DIR"

# A profile's file reference, resolved against the repo unless absolute.
src() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$SCRIPT_DIR" "$1" ;; esac; }
TAB=$(printf '\t')

# JSON string body (no surrounding quotes) for all of stdin, newlines included.
json_escape() {
    LC_ALL=C awk 'BEGIN { RS = "\001"; ORS = ""
                          for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
                          ctl["\n"] = "\\n"; ctl["\t"] = "\\t"; ctl["\r"] = "\\r" }
        { n = length($0)
          for (i = 1; i <= n; i++) {
              c = substr($0, i, 1)
              if (c == "\\" || c == "\"") printf "\\%s", c
              else if (c in ctl) printf "%s", ctl[c]
              else printf "%s", c
          } }'
}

# Print "role<TAB>content" for the system prompt and every example turn, with
# \n in an edited column expanded to a real line break (as \n escapes, so each
# turn stays on one line here).
turns() {
    printf 'system\t'
    if [ "$TRIM_PROMPT" = yes ]; then printf '%s' "$(cat "$(src "$PROMPT")")" | json_escape
    else json_escape < "$(src "$PROMPT")"; fi
    printf '\n'
    for f in $EXAMPLES; do
        while IFS="$TAB" read -r raw edited; do
            [ -n "$raw" ] || continue
            case "$raw" in '#'*) continue ;; esac
            printf 'user\t%s\n' "$(printf '%s' "$raw" | json_escape)"
            printf 'assistant\t%s\n' "$(printf '%b' "$edited" | json_escape)"
        done < "$(src "$f")"
    done
}

for profile in "$@"; do
    [ -f "$profile" ] || continue
    name=$(basename "$profile")
    PROMPT=; EXAMPLES=; CHAT_FORMAT=; TRIM_PROMPT=
    . "$profile"
    for f in $PROMPT $EXAMPLES; do
        [ -f "$(src "$f")" ] || { printf 'error: %s not found (profile %s)\n' "$f" "$name" >&2; exit 1; }
    done

    # Everything below is already JSON-escaped, so literal newlines are \n.
    case "$CHAT_FORMAT" in
        qwen-nothink)
            body=$(turns | awk -F '\t' '{ printf "<|im_start|>%s\\n%s<|im_end|>\\n", $1, $2 }')
            body="$body<|im_start|>user\\n{{TRANSCRIPT}}<|im_end|>\\n<|im_start|>assistant\\n<think>\\n\\n</think>\\n\\n"
            stop='"<|im_end|>", "<|im_start|>"'
            ;;
        chatml)
            body=$(turns | awk -F '\t' '{ printf "<|im_start|>%s\\n%s<|im_end|>\\n", $1, $2 }')
            body="$body<|im_start|>user\\n{{TRANSCRIPT}}<|im_end|>\\n<|im_start|>assistant\\n"
            stop='"<|im_end|>", "<|im_start|>"'
            ;;
        *) printf 'error: profiles/%s has unknown CHAT_FORMAT "%s"\n' "$name" "$CHAT_FORMAT" >&2; exit 1 ;;
    esac

    out="$OUT_DIR/$name.json"
    {
        printf '{\n'
        printf '  "prompt": "%s",\n' "$body"
        printf '  "stop": [%s],\n' "$stop"
        printf '  "temperature": 0,\n'
        printf '  "n_predict": 1024,\n'
        printf '  "cache_prompt": true\n'
        printf '}\n'
    } > "$out"
    printf 'wrote %s\n' "$out"
done
