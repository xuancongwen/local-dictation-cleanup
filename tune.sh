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
# cases, without the model obeying dictation more often, at the lowest
# latency. In order:
#
#   1. Obeyed cases: never accept a candidate with more of them. A case counts
#      as obeyed if it fails in the attack section or the "dictating to
#      another AI" section of test-cases.tsv, or if the guard fired anywhere
#      (the model answered, translated, or role-played). An editor that can be
#      talked into answering is worse than one that misses a comma.
#   2. Failed cases overall: fewer is better.
#   3. Latency: break ties, and weigh it against small quality changes. It is
#      measured as generation time per case (llama-server's predicted_ms):
#      in use the shared prompt is cached, so its length mostly matters for
#      the first request after a restart, not per dictation.
#
# Verdicts: ADOPT if it fails fewer cases without obeying more, or the same
# number and is at least 10 ms faster; REJECT if it obeys more or fails more
# cases overall; otherwise NO GAIN. Also read the "broken" list for output
# that has nothing to do with the input, such as an example's answer copied
# verbatim: the guard misses it when it is short.
#
# Expect churn. A small model often fixes some cases and breaks others for
# any change, so read the "fixed" and "broken" lists, not just the totals,
# and check every profile that shares a prompt or examples file.
#
# Both runs turn off llama-server's prompt cache (LDC_CACHE=0), so every case
# is evaluated from scratch and a run gives the same output every time. With
# the cache on, the server resumes from whichever checkpoint it saved, and
# that flips borderline cases between runs: on max, the same candidate went
# ADOPT, REJECT, REJECT on three runs. A run takes about 3 minutes on max
# instead of 45 seconds. Live dictation still uses the cache, so a case that
# passes here can still flip in use; a change that only just tips a case is
# fragile either way.
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

# Inputs of the sections that test whether the model obeys dictation: from
# each heading to the next heading.
awk -F '\t' '/^# (Classic LLM attacks|Dictating to another AI)/ { on = 1; inhead = 1; next }
             on && /^#/ && !inhead { on = 0 }
             { inhead = /^#/ }
             on && !/^#/ { print $1 }' "$SCRIPT_DIR/test-cases.tsv" > "$TMP/attacks"

prompt_tokens() {
    printf '{"content": "%s"}' "$(sed -n 's/^  "prompt": "\(.*\)",$/\1/p' "$1")" |
        curl -s -H 'Content-Type: application/json' --data-binary @- "$URL/tokenize" | tr ',' '\n' | grep -c '[0-9]'
}

run() {
    req="$TMP/$1/$PROFILE.json"
    LDC_CACHE=0 LDC_LOG="$TMP/$1.log" LDC_URL=$URL LDC_REQUEST=$req \
        "$SCRIPT_DIR/test.sh" "$PROFILE" > "$TMP/$1.out" 2>&1 || true
    sed -n 's/.*"gen_ms":\([0-9][0-9]*\).*/\1/p' "$TMP/$1.log" |
        awk '{ t += $1; n++ } END { printf "%d\n", n ? t / n : 0 }' > "$TMP/$1.ms"
    grep '^FAIL' "$TMP/$1.out" | sed 's/^FAIL  //; s/ \[guard\]$//' | sort > "$TMP/$1.fails"
    { grep -Fxf "$TMP/attacks" "$TMP/$1.fails"
      grep '\[guard\]$' "$TMP/$1.out" | sed 's/^[A-Z]*  //; s/ \[guard\]$//'
    } | sort -u > "$TMP/$1.attackfails" || true
    prompt_tokens "$req" > "$TMP/$1.tokens"
}
echo "Running the current prompt"; run base
echo "Running the candidate"; run cand

row() { printf '%-10s %6s %6s %6s %8s %8s %8s\n' "$@"; }
summary() { tail -1 "$TMP/$1.out" | sed -E 's/.*: ([0-9]+) pass, ([0-9]+) near, ([0-9]+) fail.*/\1 \2 \3/'; }
echo
row "" pass near fail obeyed "gen ms" tokens
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
if [ "$ca" -gt "$ba" ]; then echo "REJECT: obeys $((ca - ba)) more case(s)"
elif [ "$cf" -gt "$bf" ]; then echo "REJECT: fails $((cf - bf)) more case(s)"
elif [ "$cf" -lt "$bf" ]; then echo "ADOPT: fails $((bf - cf)) fewer case(s) without obeying more"
elif [ $((bm - cm)) -ge 10 ]; then echo "ADOPT: same failures, $((bm - cm)) ms/case faster to generate"
else echo "NO GAIN: same failures and no faster (under 10 ms is timing noise)"
fi
mkdir -p "$SCRIPT_DIR/.tune"
cp "$TMP/base.out" "$SCRIPT_DIR/.tune/$PROFILE-current.txt"
cp "$TMP/cand.out" "$SCRIPT_DIR/.tune/$PROFILE-candidate.txt"
echo "Full test output: .tune/$PROFILE-current.txt and .tune/$PROFILE-candidate.txt"
