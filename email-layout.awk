# Lay out an email that the model left on one line. Used by wrapper.sh.
#
# Input: the model's output. If it is a single line that opens with a formal
# greeting and a comma ("Hi Sarah,", "Dear Professor Lee,", "Good morning
# team,") and ends with a formal closing and a short capitalized name ("best,
# Sam.", "Kind regards, Sam Wen"), print it as greeting, body, closing, and
# signature on separate lines:
#
#   Hi Sarah,
#
#   Thanks for sending the report over.
#
#   Best,
#   Sam
#
# Anything else passes through unchanged. Chat openers and sign-offs ("Hey",
# "Cheers", "Thanks") never match, so chat messages stay on one line. The tiny
# profile wrote every dictated email on one line, and examples that showed the
# layout made it answer more requests.

{ lines[++n] = $0 }

END {
    if (n != 1) { flush(); exit }
    s = lines[1]; low = tolower(s)

    # Greeting: the opener, up to five words of recipient, then a comma.
    if (!match(low, /^(hi|hello|dear|good morning|good afternoon|good evening)( [^ ,!?:;]+){1,5},[ ]+/)) { flush(); exit }
    greet = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
    sub(/[ ]+$/, "", greet)

    # Closing and signature at the end: closing, optional comma, then one to
    # three capitalized words and an optional period.
    if (!match(rest, /[,.]?[ ]+([Bb]est regards|[Kk]ind regards|[Ww]arm regards|[Rr]egards|[Ss]incerely|[Bb]est wishes|[Aa]ll the best|[Yy]ours truly|[Bb]est)[,.]?[ ]+[A-Z][A-Za-z.'-]*( [A-Z][A-Za-z.'-]*){0,2}\.?$/)) { flush(); exit }
    body = substr(rest, 1, RSTART - 1); tail = substr(rest, RSTART)
    # "you're the best, Mark" is a compliment, not a closing; an email body
    # has a few words.
    if (tolower(body) ~ /(^|[ ])(the|my|your|our|his|her|their|all|with|very|so|send|give)$/ ||
        split(body, words, " ") < 4) { flush(); exit }

    sub(/^[,.]?[ ]+/, "", tail)
    if (!match(tail, /^([Bb]est regards|[Kk]ind regards|[Ww]arm regards|[Rr]egards|[Ss]incerely|[Bb]est wishes|[Aa]ll the best|[Yy]ours truly|[Bb]est)/)) { flush(); exit }
    closing = substr(tail, 1, RLENGTH); name = substr(tail, RLENGTH + 1)
    sub(/^[,.]?[ ]+/, "", name); sub(/\.$/, "", name)
    closing = toupper(substr(closing, 1, 1)) substr(closing, 2)

    body = toupper(substr(body, 1, 1)) substr(body, 2)
    if (body !~ /[.!?]$/) body = body "."

    printf "%s\n\n%s\n\n%s,\n%s\n", greet, body, closing, name
    exit
}

function flush(   i) { for (i = 1; i <= n; i++) print lines[i] }
