# GitHub body transport

ANY multiline body handed to `gh`—including `pr create`, `pr edit`, `issue create`, `issue edit`, and `api -f body=`—goes through a file using `--body-file` or `--input`, never an inline string. Comments already comply through `gh-comment.sh`.

Body content is data. It must never pass through interpolating heredocs or eval-adjacent expansion between authoring and the file-backed GitHub call; backticks, `$()`, and every other body byte must remain literal.

A caller that needs the created/edited object's number and URL back as data -- a bulk apply ledger, for example -- passes `gh-body.sh`'s `--json` flag instead of parsing its default human-readable lines. `--json` emits exactly one JSON object on stdout, `{"number":N,"html_url":"...","closing_issue":{...}|null}`, consumable with `jq -er '.number'`/`.html_url` with no caller-authored parsing; the human-readable lines move to stderr in that mode. Default text-mode output is unchanged.
