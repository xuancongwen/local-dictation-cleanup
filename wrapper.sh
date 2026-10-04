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
# LDC_CACHE=0 turns off llama-server's prompt cache for the request, so the
# whole prompt is evaluated from scratch (about 1 s on max instead of 0.25 s).
# Output then no longer depends on which cached checkpoint the server resumes
# from, which can flip a borderline case; tune.sh uses it for repeatable runs.
#
# Before the model call, hesitation sounds (uh, um, uhm, erm, hmm, and their
# drawn-out spellings) are dropped from the transcript, and a transcript of
# nothing else prints nothing. The models kept typing a lone "uh" or "um" back
# out. "er" is left alone ("the ER"), as are "uh-huh" and "mhm", which mean yes.
#
# Around the model call it adds four defenses against dictation that tries to
# take over the model, and against edits that change what was said:
#
#   1. Chat-template control tokens (<|im_end|>, <|start_of_role|>, <think>,
#      and the like) are stripped from the input, so text cannot close the
#      user turn and open a fake assistant or system turn.
#   2. If the output contains more than a few words the speaker never said,
#      the model has answered, translated, summarized, or role-played instead
#      of editing, and the raw transcript is printed instead.
#   3. The same happens if the output keeps under 60% of the dictated words
#      and adds two or more of its own: a short answer in place of the
#      dictation, or a rewrite of it. An edit that only drops words (a
#      resolved self-correction) passes.
#   4. The same happens if the output has a number, written in digits, that
#      the speaker never said in any form (number-check.awk): a changed port or
#      price, or the answer to dictated arithmetic.
#
# When a check fails, a note saying why goes to stderr. Otherwise a closing
# "Thank you." or the like that the speaker never said is dropped
# (courtesy.awk), and an email the model left on one line is laid out on
# separate lines (email-layout.awk).
#
# If LDC_LOG names a file, one JSON line per dictation is appended to it: the
# time, profile, model time in ms (prompt plus generation, then generation
# alone as gen_ms), the transcript as received, the model's output, what was
# printed, and why the guard fired (empty if it did not). Off by default,
# since the log keeps every dictation in plain text. A failed write is
# ignored.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
URL=${LDC_URL:-http://127.0.0.1:8189}
PROFILE=${LDC_PROFILE:-$(cat "$SCRIPT_DIR/.active-profile" 2>/dev/null || echo max)}
REQUEST=${LDC_REQUEST:-$SCRIPT_DIR/prompts/$PROFILE.json}
[ -f "$REQUEST" ] || { printf 'wrapper: no request file %s; run ./gen-prompts.sh\n' "$REQUEST" >&2; exit 1; }

raw=$(cat | sed -E 's/<\|[^|<>]*\|>//g; s#</?think>##g')
input=$(printf '%s\n' "$raw" | LC_ALL=C awk '{
    out = ""
    for (i = 1; i <= NF; i++) {
        w = tolower($i); gsub(/[^a-z]/, "", w)
        if (w ~ /^(u+h+|u+m+|u+h+m+|e+r+m+|h+m+)$/ && $i !~ /^[A-Z][A-Z]/) continue
        out = out (out == "" ? "" : " ") $i
    }
    print out }')

# All of stdin as a JSON string body (no surrounding quotes).
json_str() {
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

# Append one JSON line to LDC_LOG: model ms, model output, printed text, guard note.
log() {
    [ -n "${LDC_LOG:-}" ] || return 0
    { mkdir -p "$(dirname "$LDC_LOG")" &&
      printf '{"time":"%s","profile":"%s","ms":%s,"gen_ms":%s,"input":"%s","model":"%s","typed":"%s","guard":"%s"}\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROFILE" "${1:-null}" "${gen_ms:-null}" \
          "$(printf '%s' "$raw" | json_str)" "$(printf '%s' "$2" | json_str)" \
          "$(printf '%s' "$3" | json_str)" "$(printf '%s' "$4" | json_str)" >> "$LDC_LOG"
    } 2>/dev/null || :
}

# Nothing but hesitation sounds, or nothing at all: print nothing. voxtype
# types that only with fallback_on_empty = false.
if [ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]; then
    [ -z "$(printf '%s' "$raw" | tr -d '[:space:]')" ] || log "" "" "" ""
    exit 0
fi

# The transcript as a JSON string body, ending in \n like the examples' turns.
transcript=$(printf '%s\n' "$input" | json_str)

# Splice it in at the placeholder. ENVIRON, unlike awk -v, keeps backslashes.
body=$(T=$transcript LC_ALL=C awk 'BEGIN { RS = "\001"; ORS = "" }
    { i = index($0, "{{TRANSCRIPT}}")
      print substr($0, 1, i - 1) ENVIRON["T"] substr($0, i + 14) }' "$REQUEST")
[ "${LDC_CACHE:-1}" != 0 ] || body=$(printf '%s' "$body" | sed 's/"cache_prompt": true/"cache_prompt": false/')

response=$(printf '%s' "$body" | curl -sS --fail-with-body -H 'Content-Type: application/json' \
    --data-binary @- "$URL/completion") || {
    printf 'wrapper: request to %s failed: %s\n' "$URL" "$response" >&2
    log "" "" "" "request failed"; exit 1; }

# Prompt plus generation time, and generation time alone, from llama-server's
# own timings.
set -- $(printf '%s' "$response" | LC_ALL=C awk '{ doc = doc $0 } END {
    if (match(doc, /"prompt_ms":[0-9.]+/)) p = substr(doc, RSTART + 12, RLENGTH - 12)
    if (match(doc, /"predicted_ms":[0-9.]+/)) g = substr(doc, RSTART + 15, RLENGTH - 15)
    printf "%d %d\n", p + g, g }')
ms=$1; gen_ms=$2

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
    }') || { printf 'wrapper: unexpected response from llama-server: %s\n' "$response" >&2
             log "$ms" "" "" "unexpected response"; exit 1; }
output=$(printf '%s' "$output" | sed -e '1s/^[[:space:]]*//' -e 's/[[:space:]]*$//')

# Count output words that do not appear anywhere in the input. The input is
# compared with spaces removed, so "wifi" covers "Wi-Fi" and "dot com" covers
# ".com". Numbers are skipped because the model writes spoken numbers as
# digits. Also count the dictated words (three letters or more, other than
# spoken symbols and number words, which the model rewrites) that the output
# keeps, compared the same way.
novel=$(printf '%s\n%s\n' "$(printf '%s' "$input" | tr '\n' ' ')" "$output" | LC_ALL=C awk '
    BEGIN {
        n = split("dot slash colon question mark equals new line paragraph hyphen dash underscore " \
                  "comma period semicolon one two three four five six seven eight nine ten eleven " \
                  "twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty " \
                  "forty fifty sixty seventy eighty ninety hundred thousand million billion", sp, " ")
        for (i = 1; i <= n; i++) spoken[sp[i]] = 1
    }
    NR == 1 {
        src = tolower($0); gsub(/[^a-z0-9]/, "", src)
        line = tolower($0); gsub(/[^a-z0-9]+/, " ", line); nin = split(line, said, " ")
        next
    }
    {
        line = tolower($0); out = out line; gsub(/[^a-z0-9]+/, " ", line)
        n = split(line, w, " ")
        for (i = 1; i <= n; i++) {
            total++
            if (w[i] !~ /^[0-9]+$/ && index(src, w[i]) == 0) novel++
        }
    }
    END {
        gsub(/[^a-z0-9]/, "", out)
        for (i = 1; i <= nin; i++) {
            if (length(said[i]) < 3 || said[i] in spoken) continue
            counted++; if (index(out, said[i])) kept++
        }
        printf "%d %d %d %d\n", novel, total, kept, counted
    }')
set -- $novel; new=$1; total=$2; kept=$3; counted=$4

badnums=$(printf '%s\n%s\n' "$(printf '%s' "$input" | tr '\n' ' ')" "$output" |
    LC_ALL=C awk -f "$SCRIPT_DIR/number-check.awk")

# More than 3 unexplained words, and more than a quarter of the output. Or
# under 60% of 6+ dictated words kept, with 2+ unexplained words.
note=""
if [ "$new" -gt 3 ] && [ $((new * 4)) -gt "$total" ]; then
    note=$(printf 'output had %d of %d words not in the input' "$new" "$total")
elif [ "$counted" -ge 6 ] && [ $((kept * 10)) -lt $((counted * 6)) ] && [ "$new" -ge 2 ]; then
    note=$(printf 'output had only %d of %d dictated words, and %d not in the input' "$kept" "$counted" "$new")
elif [ -n "$badnums" ]; then
    note="output had numbers not in the input ($badnums)"
elif [ -z "$output" ]; then
    # Only a transcript of hesitation sounds should print nothing (above). An
    # empty reply to anything else would lose the dictation, so voxtype's
    # fallback_on_empty can stay off.
    note="model returned nothing"
fi
if [ -n "$note" ]; then
    printf 'wrapper: %s; typing the raw transcript\n' "$note" >&2
    typed=$input
else
    # A closing courtesy the speaker never said is dropped (courtesy.awk),
    # then a one-line email is laid out (email-layout.awk).
    typed=$(printf '%s' "$output" | T=$input LC_ALL=C awk -f "$SCRIPT_DIR/courtesy.awk" |
        LC_ALL=C awk -f "$SCRIPT_DIR/email-layout.awk")
fi
log "$ms" "$output" "$typed" "$note"
printf '%s\n' "$typed"
