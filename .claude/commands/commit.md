## Commit

- before any operation, switch the current working directory to the project root directory
- commit the local change to git repository with a proper message in English
- don't add co-author in commit message
- remove ./tmp/commit_message.txt if it exists
- write the commit message with the Write tool instead of a heredoc to ./tmp/commit_message.txt 
- then `git commit -F ./tmp/commit_message.txt`
