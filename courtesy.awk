# Drop a closing courtesy the speaker never said. Used by wrapper.sh.
#
# Input: the model's output. ENVIRON["T"] is the transcript. If the last
# sentence is only "Thank you.", "Thanks!", "Hope this helps." or the like,
# it follows another sentence, and the transcript has no such words, print the
# output without it. A long dictated bug report that ended in a question came
# back with "Thank you." added. Anything else passes through unchanged.

BEGIN { RS = "\001"; ORS = "" }

{
    s = $0; sub(/[ \n]+$/, "", s)
    # The last sentence: letters, spaces, commas and apostrophes after a
    # sentence end, to the end of the text.
    if (!match(s, /[.!?:]["')]?[ \n]+[A-Za-z][A-Za-z' ,]*[.!]?$/)) { print s; exit }
    start = RSTART; tail = substr(s, RSTART)
    match(tail, /[A-Za-z]/); keep = substr(s, 1, start + RSTART - 2)
    last = tolower(substr(tail, RSTART)); gsub(/[^a-z ]/, " ", last)
    gsub(/ +/, " ", last); sub(/^ /, "", last); sub(/ $/, "", last)
    if (last !~ /^(thank you|thank you so much|thank you very much|thanks|thanks so much|thanks a lot|many thanks|hope this helps|hope that helps|i hope this helps|i hope that helps)$/) { print s; exit }
    said = tolower(ENVIRON["T"]); gsub(/[^a-z]/, "", said)
    key = last; gsub(/ /, "", key)
    if (index(said, key)) { print s; exit }
    sub(/[ \n]+$/, "", keep)
    print keep
}
