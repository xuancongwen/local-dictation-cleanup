#!/bin/sh
# Edit a dictated transcript with the local-dictation-cleanup model. This is the
# command voxtype's [output.post_process] runs.
#
# Usage: printf '%s\n' "raw transcript" | ./wrapper.sh
#
# It fills the transcript into the active profile's request (prompts/<profile>
# .json, rendered by gen-prompts.sh) and sends it to llama-server, which
# setup.sh runs as a user service with that profile's model loaded. The
# profile comes from LDC_PROFILE, else the .active-profile file setup.sh
# writes, else max. LDC_URL overrides the server address and LDC_REQUEST the
# request file. Only curl is needed; JSON is encoded and decoded in awk.
#
# Around the model call it adds three defenses against dictation that tries to
# take over the model, and against edits that change what was said:
#
#   1. Chat-template control tokens (<|im_end|>, <|start_of_role|>, <think>,
#      and the like) are stripped from the input, so text cannot close the
#      user turn and open a fake assistant or system turn.
#   2. If the output contains more than a few words the speaker never said,
#      the model has answered, translated, summarized, or role-played instead
#      of editing, and the raw transcript is printed instead.
#   3. The same happens if the output has a number, written in digits, that
#      the speaker never said in any form (number-check.awk): a changed port or
#      price, or the answer to dictated arithmetic.
#
# When a check fails, a note saying why goes to stderr.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
URL=${LDC_URL:-http://127.0.0.1:8189}
PROFILE=${LDC_PROFILE:-$(cat "$SCRIPT_DIR/.active-profile" 2>/dev/null || echo max)}
REQUEST=${LDC_REQUEST:-$SCRIPT_DIR/prompts/$PROFILE.json}
[ -f "$REQUEST" ] || { printf 'wrapper: no request file %s; run ./gen-prompts.sh\n' "$REQUEST" >&2; exit 1; }

input=$(cat | sed -E 's/<\|[^|<>]*\|>//g; s#</?think>##g')
[ -n "$(printf '%s' "$input" | tr -d '[:space:]')" ] || exit 0

# The transcript as a JSON string body, ending in \n like the examples' turns.
transcript=$(printf '%s\n' "$input" | LC_ALL=C awk '
    BEGIN { RS = "\001"; ORS = ""
            for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
            ctl["\n"] = "\\n"; ctl["\t"] = "\\t"; ctl["\r"] = "\\r" }
    { n = length($0)
      for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (c == "\\" || c == "\"") printf "\\%s", c
          else if (c in ctl) printf "%s", ctl[c]
          else printf "%s", c
      } }')

# Splice it in at the placeholder. ENVIRON, unlike awk -v, keeps backslashes.
body=$(T=$transcript LC_ALL=C awk 'BEGIN { RS = "\001"; ORS = "" }
    { i = index($0, "{{TRANSCRIPT}}")
      print substr($0, 1, i - 1) ENVIRON["T"] substr($0, i + 14) }' "$REQUEST")

response=$(printf '%s' "$body" | curl -sS --fail-with-body -H 'Content-Type: application/json' \
    --data-binary @- "$URL/completion") || {
    printf 'wrapper: request to %s failed: %s\n' "$URL" "$response" >&2; exit 1; }

# Pull "content" out of the response and undo its JSON escapes.
output=$(printf '%s' "$response" | LC_ALL=C awk '
    function utf8(cp) {
        if (cp < 128) return sprintf("%c", cp)
        if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
        if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
        return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
    }
    function hex(h,   i, v) { v = 0; h = tolower(h); for (i = 1; i <= 4; i++) v = v * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return v }
    { doc = doc $0 }
    END {
        i = index(doc, "\"content\":\""); if (!i) exit 1
        doc = substr(doc, i + 11); n = length(doc); out = ""
        for (i = 1; i <= n; i++) {
            c = substr(doc, i, 1)
            if (c == "\"") break
            if (c != "\\") { out = out c; continue }
            c = substr(doc, ++i, 1)
            if (c == "n") out = out "\n"; else if (c == "t") out = out "\t"; else if (c == "r") out = out "\r"
            else if (c == "b") out = out "\b"; else if (c == "f") out = out "\f"
            else if (c == "u") {
                cp = hex(substr(doc, i + 1, 4)); i += 4
                if (cp >= 55296 && cp < 56320 && substr(doc, i + 1, 2) == "\\u") {
                    lo = hex(substr(doc, i + 3, 4)); i += 6; cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
                }
                out = out utf8(cp)
            } else out = out c
        }
        printf "%s", out
    }') || { printf 'wrapper: unexpected response from llama-server: %s\n' "$response" >&2; exit 1; }
output=$(printf '%s' "$output" | sed -e '1s/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Count output words that do not appear anywhere in the input. The input is
# compared with spaces removed, so "wifi" covers "Wi-Fi" and "dot com" covers
# ".com". Numbers are skipped because the model writes spoken numbers as
# digits.
novel=$(printf '%s\n%s\n' "$(printf '%s' "$input" | tr '\n' ' ')" "$output" | LC_ALL=C awk '
    NR == 1 { src = tolower($0); gsub(/[^a-z0-9]/, "", src); next }
    {
        line = tolower($0); gsub(/[^a-z0-9]+/, " ", line)
        n = split(line, w, " ")
        for (i = 1; i <= n; i++) {
            total++
            if (w[i] !~ /^[0-9]+$/ && index(src, w[i]) == 0) novel++
        }
    }
    END { printf "%d %d\n", novel, total }')
new=${novel% *}; total=${novel#* }

badnums=$(printf '%s\n%s\n' "$(printf '%s' "$input" | tr '\n' ' ')" "$output" |
    LC_ALL=C awk -f "$SCRIPT_DIR/number-check.awk")

# More than 3 unexplained words, and more than a quarter of the output.
if [ "$new" -gt 3 ] && [ $((new * 4)) -gt "$total" ]; then
    printf 'wrapper: output had %d of %d words not in the input; typing the raw transcript\n' "$new" "$total" >&2
    printf '%s\n' "$input"
elif [ -n "$badnums" ]; then
    printf 'wrapper: output had numbers not in the input (%s); typing the raw transcript\n' "$badnums" >&2
    printf '%s\n' "$input"
else
    printf '%s\n' "$output"
fi
