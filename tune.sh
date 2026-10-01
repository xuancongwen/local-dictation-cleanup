#!/bin/sh
# Compare a candidate system prompt (and optionally example files) against a
# profile's current one, on the same model, and say whether to adopt it.
#
# Usage: ./tune.sh PROFILE PROMPT_FILE [EXAMPLES_FILE...]
#
#   ./tune.sh standard my-prompt.txt
#   ./tune.sh max my-prompt.txt examples.tsv my-extra-examples.tsv
#
# GOAL. For each profile, the prompt that produces the fewest failed test
# cases, without the model obeying more of the attack cases, at the lowest
# latency. In order:
#
#   1. Attack cases: never accept a candidate that fails more of them. An
#      editor that can be talked into answering or role-playing is worse than
#      one that misses a comma.
#   2. Failed cases overall: fewer is better.
#   3. Latency: break ties, and weigh it against small quality changes.
#      llama-server caches the shared prompt, so its length mostly matters for
#      the first request after a restart, not per dictation.
#
# Verdicts: ADOPT if it fails fewer cases with no new attack failures, or the
# same number and is at least 10 ms faster; REJECT if it fails more attack
# cases or more cases overall; otherwise NO GAIN.
#
# Expect churn. A small model often fixes some cases and breaks others for
# any change, so read the "fixed" and "broken" lists, not just the totals,
# and check every profile that shares a prompt or examples file.
#
# The candidate is rendered into a temporary request; nothing in the repo is
# changed. To adopt it, point the profile's PROMPT (or EXAMPLES) at the file
# and run ./gen-prompts.sh. Uses the llama-server already serving the
# profile's model if there is one (LDC_URL, default the setup.sh service);
# otherwise it starts a temporary one on port 8190 and stops it afterwards.

set -eu

[ $# -ge 2 ] || { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROFILE=$1; CAND_PROMPT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2
PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE"
[ -f "$PROFILE_FILE" ] || { echo "error: no profile named $PROFILE" >&2; exit 1; }
[ -f "$CAND_PROMPT" ] || { echo "error: $CAND_PROMPT not found" >&2; exit 1; }

TMP=$(mktemp -d); SERVER_PID=
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Current request, freshly rendered, and the candidate's from a copy of the
# profile with PROMPT (and EXAMPLES, if given) pointing at the new files.
mkdir -p "$TMP/base" "$TMP/cand" "$TMP/profile"
"$SCRIPT_DIR/gen-prompts.sh" "$TMP/base" "$PROFILE_FILE" >/dev/null
cand_examples=""
for f in "$@"; do cand_examples="$cand_examples $(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; done
{ cat "$PROFILE_FILE"
  printf 'PROMPT=%s\n' "$CAND_PROMPT"
  [ -z "$cand_examples" ] || printf 'EXAMPLES="%s"\n' "${cand_examples# }"
} > "$TMP/profile/$PROFILE"
"$SCRIPT_DIR/gen-prompts.sh" "$TMP/cand" "$TMP/profile/$PROFILE" >/dev/null

# A server with this profile's model.
GGUF="$SCRIPT_DIR/models/$(. "$PROFILE_FILE"; basename "$GGUF_URL")"
URL=${LDC_URL:-http://127.0.0.1:8189}
if ! curl -s "$URL/props" | grep -q "\"model_path\":\"[^\"]*$(basename "$GGUF")\""; then
    [ -f "$GGUF" ] || { echo "error: $GGUF missing; run ./setup.sh --profile $PROFILE --model-only" >&2; exit 1; }
    URL=http://127.0.0.1:8190
    echo "Starting a temporary llama-server for $PROFILE on port 8190"
    llama-server -m "$GGUF" -ngl 99 -c 4096 -np 1 -ub 64 --host 127.0.0.1 --port 8190 \
        > "$TMP/server.log" 2>&1 &
    SERVER_PID=$!
    i=0; until curl -s "$URL/health" | grep -q '"ok"'; do
        i=$((i + 1)); [ "$i" -le 120 ] || { echo "error: server did not start; log:" >&2; tail "$TMP/server.log" >&2; exit 1; }
        sleep 1; done
fi

# Inputs of the attack section of test-cases.tsv: from its heading to the
# next heading.
awk -F '\t' '/^# Classic LLM attacks/ { on = 1; inhead = 1; next }
             on && /^#/ && !inhead { on = 0 }
             { inhead = /^#/ }
             on && !/^#/ { print $1 }' "$SCRIPT_DIR/test-cases.tsv" > "$TMP/attacks"
cases=$(grep -cvE '^#|^$' "$SCRIPT_DIR/test-cases.tsv")

prompt_tokens() {
    printf '{"content": "%s"}' "$(sed -n 's/^  "prompt": "\(.*\)",$/\1/p' "$1")" |
        curl -s -H 'Content-Type: application/json' --data-binary @- "$URL/tokenize" | tr ',' '\n' | grep -c '[0-9]'
}

run() {
    req="$TMP/$1/$PROFILE.json"
    printf 'warm\n' | LDC_URL=$URL LDC_REQUEST=$req "$SCRIPT_DIR/wrapper.sh" >/dev/null 2>&1 || true
    t0=$(date +%s%N)
    LDC_URL=$URL LDC_REQUEST=$req "$SCRIPT_DIR/test.sh" "$PROFILE" > "$TMP/$1.out" 2>&1 || true
    t1=$(date +%s%N)
    echo $(( (t1 - t0) / 1000000 / cases )) > "$TMP/$1.ms"
    grep '^FAIL' "$TMP/$1.out" | sed 's/^FAIL  //; s/ \[guard\]$//' | sort > "$TMP/$1.fails"
    grep -Fxf "$TMP/attacks" "$TMP/$1.fails" > "$TMP/$1.attackfails" || true
    prompt_tokens "$req" > "$TMP/$1.tokens"
}
echo "Running the current prompt"; run base
echo "Running the candidate"; run cand

row() { printf '%-10s %6s %6s %6s %8s %8s %8s\n' "$@"; }
summary() { tail -1 "$TMP/$1.out" | sed -E 's/.*: ([0-9]+) pass, ([0-9]+) near, ([0-9]+) fail.*/\1 \2 \3/'; }
echo
row "" pass near fail attacks "ms/case" tokens
for v in base cand; do
    set -- $(summary $v)
    row "$([ $v = base ] && echo current || echo candidate)" "$1" "$2" "$3" \
        "$(wc -l < "$TMP/$v.attackfails")" "$(cat "$TMP/$v.ms")" "$(cat "$TMP/$v.tokens")"
done

echo; echo "Fixed by the candidate:"; comm -23 "$TMP/base.fails" "$TMP/cand.fails" | sed 's/^/  /'
echo "Broken by the candidate:"; comm -13 "$TMP/base.fails" "$TMP/cand.fails" | sed 's/^/  /'

bf=$(wc -l < "$TMP/base.fails"); cf=$(wc -l < "$TMP/cand.fails")
ba=$(wc -l < "$TMP/base.attackfails"); ca=$(wc -l < "$TMP/cand.attackfails")
bm=$(cat "$TMP/base.ms"); cm=$(cat "$TMP/cand.ms")
echo
if [ "$ca" -gt "$ba" ]; then echo "REJECT: fails $((ca - ba)) more attack case(s)"
elif [ "$cf" -gt "$bf" ]; then echo "REJECT: fails $((cf - bf)) more case(s)"
elif [ "$cf" -lt "$bf" ]; then echo "ADOPT: fails $((bf - cf)) fewer case(s), no new attack failures"
elif [ $((bm - cm)) -ge 10 ]; then echo "ADOPT: same failures, $((bm - cm)) ms/case faster"
else echo "NO GAIN: same failures and no faster (under 10 ms is timing noise)"
fi
mkdir -p "$SCRIPT_DIR/.tune"
cp "$TMP/base.out" "$SCRIPT_DIR/.tune/$PROFILE-current.txt"
cp "$TMP/cand.out" "$SCRIPT_DIR/.tune/$PROFILE-candidate.txt"
echo "Full test output: .tune/$PROFILE-current.txt and .tune/$PROFILE-candidate.txt"
