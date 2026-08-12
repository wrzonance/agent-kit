# GitHub body transport

ANY multiline body handed to `gh`—including `pr create`, `pr edit`, `issue create`, `issue edit`, and `api -f body=`—goes through a file using `--body-file` or `--input`, never an inline string. Comments already comply through `gh-comment.sh`.

Body content is data. It must never pass through interpolating heredocs or eval-adjacent expansion between authoring and the file-backed GitHub call; backticks, `$()`, and every other body byte must remain literal.
