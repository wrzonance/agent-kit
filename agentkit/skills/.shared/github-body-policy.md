# GitHub body transport

ANY multiline body handed to `gh`—including `pr create`, `pr edit`, `issue create`, `issue edit`, and `api -f body=`—goes through a file using `--body-file` or `--input`, never an inline string. Comments already comply through `gh-comment.sh`.

Body content is data. It must never pass through interpolating heredocs or eval-adjacent expansion between authoring and the file-backed GitHub call; backticks, `$()`, and every other body byte must remain literal.

A caller that needs the created/edited object's number and URL back as data passes `gh-body.sh`'s `--json` flag: exactly one JSON object on stdout (`{"number":N,"html_url":"...","closing_issue":{...}|null}`) for any successful mutation — including one whose closing-issue verification later failed — and nothing on stdout when the mutation itself fails; human-readable lines move to stderr in that mode.
