#!/bin/sh
# Edit a dictated transcript with the voxtype-llm-wrapper model. This is the
# command voxtype's [output.post_process] runs.
#
# Usage: printf '%s\n' "raw transcript" | ./wrapper.sh [MODEL_NAME]
#
# Around the model call it adds two defenses against dictation that tries to
# take over the model:
#
#   1. Chat-template control tokens (<|im_end|>, <|start_of_role|>, <think>,
#      and the like) are stripped from the input, so text cannot close the
#      user turn and open a fake assistant or system turn.
#   2. If the output contains more than a few words the speaker never said,
#      the model has answered, translated, summarized, or role-played instead
#      of editing, and the raw transcript is printed instead. A note goes to
#      stderr.
#
# MODEL_NAME defaults to voxtype-llm-wrapper. Extra flags for "ollama run" can
# be passed in RUN_ARGS.

set -u

MODEL=${1:-voxtype-llm-wrapper}

input=$(cat | sed -E 's/<\|[^|<>]*\|>//g; s#</?think>##g')
[ -n "$(printf '%s' "$input" | tr -d '[:space:]')" ] || exit 0

output=$(printf '%s\n' "$input" | ollama run --nowordwrap ${RUN_ARGS:-} "$MODEL") || exit 1

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

# More than 3 unexplained words, and more than a quarter of the output.
if [ "$new" -gt 3 ] && [ $((new * 4)) -gt "$total" ]; then
    printf 'wrapper: output had %d of %d words not in the input; typing the raw transcript\n' "$new" "$total" >&2
    printf '%s\n' "$input"
else
    printf '%s\n' "$output"
fi
