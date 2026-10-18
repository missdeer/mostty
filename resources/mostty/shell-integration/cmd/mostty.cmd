@echo off
if defined MOSTTY_CMD_INTEGRATED goto :eof
set "MOSTTY_CMD_INTEGRATED=1"
if not defined PROMPT set "PROMPT=$P$G"
rem Raw kitty-shell-cwd avoids treating percent characters in Windows paths as URI escapes.
set "PROMPT=$E]7;kitty-shell-cwd://localhost/$P$E\$E]2;$P$E\%PROMPT%"
