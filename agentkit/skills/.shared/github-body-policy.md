# GitHub body transport

ANY multiline body handed to `gh`—including `pr create`, `pr edit`, `issue create`, `issue edit`, and `api -f body=`—goes through a file using `--body-file` or `--input`, never an inline string. Comments already comply through `gh-comment.sh`.
