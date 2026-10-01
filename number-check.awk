# Print every number the model wrote in digits that the speaker never said.
# Input: line 1 is the dictation, the remaining lines are the model's output.
# wrapper.sh types the raw transcript instead if anything is printed.
#
# Accepted: digits already in the dictation, and any value the spoken words
# could mean: "three thousand" 3000, "four hundred and fifty" 450, "fifteenth"
# 15, "nineteen ninety nine" 19, 99, and 1999, "five five five one two three
# four" 5551234 and each run within it, "four oh four" 404. Ignored: list
# numbering at the start of a line, runs of zeros (4:00), and thousands commas.
function add(v) { acc[v ""] = 1 }
function flush() {
    if (!open) return
    v = sprintf("%d", total + group); add(v); chunk[++nc] = v
    total = 0; group = 0; last = ""; open = 0
}
function endrun(   i, j, s) {
    flush()
    # Numbers said piece by piece: "five five five one two" is 55512 as well.
    for (i = 1; i <= nc; i++) { s = ""; for (j = i; j <= nc && length(s) < 16; j++) { s = s chunk[j]; add(s) } }
    nc = 0
}
BEGIN {
    n = split("zero oh one two three four five six seven eight nine", w, " ")
    for (i = 1; i <= n; i++) unit[w[i]] = (i <= 2 ? 0 : i - 2)
    split("first second third fourth fifth sixth seventh eighth ninth", w, " ")
    for (i = 1; i <= 9; i++) unit[w[i]] = i
    split("ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen", w, " ")
    for (i = 1; i <= 10; i++) teen[w[i]] = i + 9
    split("tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth", w, " ")
    for (i = 1; i <= 10; i++) teen[w[i]] = i + 9
    split("twenty thirty forty fifty sixty seventy eighty ninety", w, " ")
    for (i = 1; i <= 8; i++) tens[w[i]] = (i + 1) * 10
    split("twentieth thirtieth fortieth fiftieth sixtieth seventieth eightieth ninetieth", w, " ")
    for (i = 1; i <= 8; i++) tens[w[i]] = (i + 1) * 10
    scale["thousand"] = 1000; scale["million"] = 1000000; scale["billion"] = 1000000000
}
NR == 1 {
    line = tolower($0); gsub(/[^a-z0-9]+/, " ", line)
    n = split(line, w, " ")
    for (i = 1; i <= n; i++) {
        t = w[i]
        if (t ~ /^[0-9]+$/) { endrun(); add(t); sub(/^0+/, "", t); add(t); continue }
        if (t ~ /[0-9]/) { endrun(); s = t; gsub(/[^0-9]+/, " ", s); m = split(s, d, " "); for (k = 1; k <= m; k++) add(d[k]); continue }
        if (t == "a" && (w[i + 1] == "hundred" || w[i + 1] in scale)) t = "one"
        if (t in unit) {
            u = unit[t]; add(u)
            if (last == "unit" || last == "teen") flush()
            group += u; last = "unit"; open = 1
        } else if (t in teen) {
            add(teen[t])
            if (last != "" && last != "hundred" && last != "scale") flush()
            group += teen[t]; last = "teen"; open = 1
        } else if (t in tens) {
            add(tens[t])
            if (last != "" && last != "hundred" && last != "scale") flush()
            group += tens[t]; last = "tens"; open = 1
        } else if (t == "hundred") {
            if (group == 0) group = 1
            group *= 100; last = "hundred"; open = 1
        } else if (t in scale) {
            if (group == 0 && total == 0) group = 1
            total += group * scale[t]; group = 0; last = "scale"; open = 1
        } else if (t == "and" && open) {
            continue
        } else endrun()
    }
    endrun()
    next
}
{
    line = $0
    sub(/^[ \t]*[0-9]+[.)][ \t]+/, "", line)                 # list numbering
    while (match(line, /[0-9],[0-9][0-9][0-9]/))              # 3,000
        line = substr(line, 1, RSTART) substr(line, RSTART + 2)
    gsub(/[^0-9]+/, " ", line)
    m = split(line, d, " ")
    for (k = 1; k <= m; k++) {
        t = d[k]; if (t ~ /^0+$/) continue
        u = t; sub(/^0+/, "", u)
        if (!(t in acc) && !(u in acc)) bad = bad (bad == "" ? "" : " ") t
    }
}
END { print bad }
