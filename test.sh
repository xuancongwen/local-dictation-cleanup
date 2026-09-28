#!/bin/sh
# Run the dictation cases in test-cases.tsv through wrapper.sh, exactly as
# voxtype does, and report how closely each output matches the expected text.
#
# Usage: ./test.sh [MODEL_NAME]
#
# MODEL_NAME defaults to voxtype-llm-wrapper. Each line of test-cases.tsv is
# "input<TAB>expected", with \n in the expected column standing for a line
# break and <empty> meaning the model should output nothing. Lines with an
# empty expected column are printed for eyeballing but not scored.
#
# Each scored case gets one of:
#   PASS  exact match
#   NEAR  same words after dropping case, punctuation, whitespace, and list
#         markers, and the same layout; only style differs (a curly quote, an
#         Oxford comma, bullets vs numbers, one blank line vs two)
#   FAIL  different words (content was answered, dropped, added, or rewritten),
#         or the wrong layout: one line where several were expected or the
#         reverse, e.g. a chat message formatted as an email
#
# A case marked [guard] is one where wrapper.sh rejected the model's output and
# passed the raw transcript through. It scores as a FAIL, since the model
# answered or rewrote instead of editing, though what got typed was harmless.
#
# Extra flags for "ollama run" can be passed in the RUN_ARGS environment
# variable, e.g. RUN_ARGS=--think=false for a model with a thinking mode.
#
# Exit status is non-zero if any scored case FAILs. NEAR does not fail.

set -u

MODEL=${1:-voxtype-llm-wrapper}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CASES="$SCRIPT_DIR/test-cases.tsv"

command -v ollama >/dev/null 2>&1 || { echo "error: ollama not found" >&2; exit 1; }
[ -f "$CASES" ] || { echo "error: $CASES not found" >&2; exit 1; }

# Drop list markers, lowercase, and strip everything that is not a letter or digit.
lenient() {
    printf '%s\n' "$1" | sed -E 's/^[[:space:]]*([-*•]|[0-9]+[.)])[[:space:]]+//' |
        tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}
# "multi" if the text has more than one non-blank line, else "single".
layout() { [ "$(printf '%s\n' "$1" | grep -c '[^[:space:]]')" -gt 1 ] && echo multi || echo single; }
oneline() { printf '%s' "$1" | tr '\n' '|'; }

ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
pass=0; near=0; fail=0; unscored=0; guarded=0
TAB=$(printf '\t')
while IFS="$TAB" read -r input expected; do
    [ -n "$input" ] || continue
    case "$input" in '#'*) continue ;; esac
    got=$(printf '%s\n' "$input" | "$SCRIPT_DIR/wrapper.sh" "$MODEL" 2>"$ERR" | sed -e 's/[[:space:]]*$//')
    guard=""; grep -q 'wrapper: output had' "$ERR" && guard=" [guard]" && guarded=$((guarded + 1))
    if [ -z "$expected" ]; then
        unscored=$((unscored + 1))
        printf '....  %s%s\n   -> %s\n' "$input" "$guard" "$(oneline "$got")"
        continue
    fi
    [ "$expected" = "<empty>" ] && expected=""
    expected=$(printf '%b' "$expected")
    if [ -n "$guard" ]; then
        fail=$((fail + 1))
        printf 'FAIL  %s%s\n   want: %s\n   got:  %s\n' "$input" "$guard" "$(oneline "$expected")" "$(oneline "$got")"
    elif [ "$got" = "$expected" ]; then
        pass=$((pass + 1))
        printf 'PASS  %s%s\n' "$input" "$guard"
    elif [ "$(lenient "$got")" = "$(lenient "$expected")" ] && [ "$(layout "$got")" = "$(layout "$expected")" ]; then
        near=$((near + 1))
        printf 'NEAR  %s%s\n   want: %s\n   got:  %s\n' "$input" "$guard" "$(oneline "$expected")" "$(oneline "$got")"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s%s\n   want: %s\n   got:  %s\n' "$input" "$guard" "$(oneline "$expected")" "$(oneline "$got")"
    fi
done < "$CASES"

printf '\n%s: %d pass, %d near, %d fail, %d unscored, %d guarded\n' "$MODEL" "$pass" "$near" "$fail" "$unscored" "$guarded"
[ "$fail" -eq 0 ]
