# AGENTS.md

## Tracking work

Use the Trackstar project `local-dictation-cleanup` to track what this
repository is working on and what it plans next. Don't keep that in
README.md, TODO files, `.tune/`, or GitHub issues (issues #1–#9 were moved to
Trackstar on 2026-10-04 and are kept only for history).

- Open a story before starting a piece of work, and set it to started. Comment
  on it with findings as you go: `tune.sh` and `test.sh` numbers, candidates
  tried and rejected, and why.
- When the work lands, mark the story finished and reference it from the
  commit (`Trackstar: local-dictation-cleanup story N`). Leave accepting it to
  the person who reviews it.
- If work stops without a fix, record what was tried and move the story back
  out of started, so started means someone is on it.
- Record known failures and ideas as stories (bugs, features, or chores), so
  the plan lives in one place. Ideas go in the icebox; planned work goes in
  the backlog, ordered by priority.
- Label stories by profile (`profile: max`, `profile: tiny`, and so on), and by
  area where one fits (`guard`, `prompts`, `testing`, `languages`). Each
  profile has a tracking story that lists its history and open work (e.g.
  [#568] for `max`). Update it when you open or close one of that profile's
  stories.
- Link stories as `[#id]` in descriptions and comments; a bare `#id` stays
  plain text.
