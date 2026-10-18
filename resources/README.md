# Mostty integration resources

The macOS app ships this tree in `Mostty.app/Contents/Resources`. Windows
builds ship it in `share/` next to the distribution's executable and themes.

## Shell integration

On Windows, interactive PowerShell (`pwsh` and Windows PowerShell), cmd, and
Git Bash receive integration automatically. PowerShell keeps its normal profiles
and prompt and reports titles, directories and OSC 133 prompt/command boundaries.
cmd keeps its existing prompt and reports titles and directories; it does not
report semantic command boundaries. Git Bash uses the bundled Bash hooks and
preserves its startup-file options. `shell-integration = false` disables injection.
Shell command/script arguments and unrecognized launchers (including WSL wrappers)
are passed through without injection. WSL users can install/source the Bash/Zsh
resources inside their distribution; POSIX-only directories are not inherited as
Windows directories.

Windows looks for `share/mostty` beside the executable (distribution layout), then
in its parent (the `zig-out/bin` build layout), or uses `MOSTTY_RESOURCES_DIR`.
New tabs and splits inherit the active pane's existing local drive directory unless
the launcher specifies a directory. OSC 7 URI escapes and Git Bash `/c/...` drive
paths are decoded; remote hosts, UNC reports, malformed URIs and WSL paths are
excluded from local inheritance.

On macOS, supported interactive login shells receive the bundled integration
automatically. Zsh retains the user's `ZDOTDIR`, `.zshenv`, `.zprofile`, and
`.zshrc`; modern Bash retains its normal login startup files. Apple's `/bin/bash`
(3.2) keeps its normal startup and requires the manual `source` below, matching
Ghostty's limitation. Fish and Nushell discover
vendor integration through `XDG_DATA_DIRS`. Elvish keeps its own RC loader and
discovers the bundled module through that variable; enable it in your `rc.elv`:

```elvish
if (and (has-env MOSTTY_RESOURCES_DIR) (not-eq $E:MOSTTY_RESOURCES_DIR "")) {
  use mostty-integration
}
```

Noninteractive launcher commands are not injected.

The integration reports titles, the working directory, and semantic prompt
boundaries. New tabs and splits inherit the active pane's local working directory
unless their launcher specifies one. Remote OSC 7 hosts are not inherited as
local directories. Closing sessions keeps the configured confirmation policy.

Use `shell-integration = false` (or `none`) to disable injection for new sessions.
`MOSTTY_RESOURCES_DIR` may point to this tree's `mostty/` directory for development
or manual integration. `TERM` remains `xterm-256color`; no Ghostty-specific SSH,
sudo, terminfo installation or cache commands are enabled.

For a nested shell, source the corresponding file from its startup config:

```sh
# Bash
if [ -n "${MOSTTY_RESOURCES_DIR:-}" ]; then
    source "$MOSTTY_RESOURCES_DIR/shell-integration/bash/mostty.bash"
fi
```

```zsh
# Zsh
if [[ -n ${MOSTTY_RESOURCES_DIR:-} ]]; then
    source "$MOSTTY_RESOURCES_DIR/shell-integration/zsh/mostty-integration"
fi
```

The shell scripts are adapted from Ghostty's macOS bundle. Bash and Zsh scripts
retain their GPLv3-or-later headers; `COPYING.GPLv3` is included. The Bash hook
library retains its authors and MIT license in `LICENSE.bash-preexec`. The other
Ghostty-derived scripts carry `LICENSE.Ghostty`. The Nushell file enables its
native terminal protocols rather than importing Ghostty-specific wrappers.

## Editors and command completion

Vim and Neovim resources detect `*.mostty` and Mostty's standard config paths,
highlight supported keys and colors, set comment rules, and provide syntax-based
keyword completion. `:make` runs `Mostty +validate-config --config-file <file>`
and loads parser diagnostics into the quickfix list. Invalid configuration exits
with status 1; file access errors return a nonzero status. Normal app startup still
warns and uses defaults for invalid entries.

Neovim discovers `nvim/site` through the injected `XDG_DATA_DIRS`. For Vim, add
the installed `vim/vimfiles` directory to `runtimepath`, before `filetype plugin on`:

```vim
set runtimepath^=/Applications/Mostty.app/Contents/Resources/vim/vimfiles
filetype plugin on
syntax on
```

Zsh, modern Bash and Fish integration makes their bundled `Mostty` completions available.
Outside Mostty, source `bash-completion/completions/Mostty`, add `zsh/site-functions`
to `fpath` before `compinit`, or install `fish/vendor_completions.d/*.fish` in the
user's Fish completions directory. Renderer and `--ttf` options are Windows-only.
`Mostty +list-themes` lists available themes without starting a window.

For `bat`, install `bat/syntaxes/mostty.sublime-syntax` under the directory printed
by `bat --config-dir`, then run `bat cache --build`. Use
`bat --language 'Mostty Config' <config-file>` for a config with no extension.

## Terminal automation (Windows)

`Mostty +control [--target-process <pid>]` reads one UTF-8 JSON request from stdin
and writes a JSON response to stdout, without opening a terminal window. Select
the process explicitly when several Mostty windows are running. The bundled
PowerShell client handles UTF-8, quoting, output capture and error responses:

```powershell
$control = './share/mostty/Invoke-Mostty.ps1'
$pane = (& $control -Request @{ action = 'new_tab'; directory = 'C:\work' }).terminal
& $control -Request @{ action = 'input'; id = $pane.id; text = "pwd`r" }
& $control -Request @{ action = 'split'; id = $pane.id; direction = 'down' }
& $control -Request @{ action = 'get'; id = $pane.id }
& $control -Request @{ action = 'list' }
```

Actions are `list`, `get`, `new_tab`, `focus`, `split`, `input` and `close`.
Omit `id` to address the active pane. `new_tab` accepts an optional `command`
(a Windows launcher command line) and `directory`. Split directions are `right`
and `down`. Input is literal; include a carriage return to submit a command.
Responses include `ok`, `error`, `terminal` and `terminals`; terminal details include
`id`, `title`, `directory`, `at_prompt` and `active`. IDs belong to one process
instance; closed panes and IDs from another instance fail. Close follows
`confirm-close-surface`; cancelling returns `CloseCancelled`, and successful
close is queued through the normal pane lifecycle. Configuration changes to the
confirmation policy apply to keyboard/menu and window close as well.

The transport uses synchronous `WM_COPYDATA` on the application UI thread, with
64 KiB request/response limits. It uses normal Windows message access rules;
controlling an elevated Mostty requires a client at the same integrity level.
Transport/argument errors exit with status 2; rejected operations exit with 1.
The client waits up to two minutes for a request, including any confirmation
dialog. A timeout leaves the operation's outcome unknown; inspect the live panes
before retrying an operation that creates, inputs to, or closes a session.

## AppleScript (macOS)

`Mostty.sdef` exposes a flat list of terminal panes. IDs are stable within an app
process; closed or invalid IDs return errors. Commands default to the active
terminal when an ID is omitted. Input is literal: include `return` to submit a
shell command.

```applescript
tell application "Mostty"
    set pane to new tab working directory "/usr"
    set paneID to id of pane
    input text "pwd" & return to terminal paneID
    set otherPane to split terminal paneID direction "down"
    focus terminal paneID
    get {name, working directory, at prompt} of pane
end tell
```

`close terminal paneID` follows `confirm-close-surface`; cancelling the dialog
returns a script error and preserves the session.

## Shortcuts (macOS)

Apple's build tools generate `Metadata.appintents` from the actual Swift actions.
The Shortcuts app can discover New Terminal Tab, Focus Terminal, Close Terminal,
Input Text to Terminal, Split Terminal, and Get Terminal Details. New Tab and
Split return a terminal entity for use by later actions. Terminal choices resolve
against live pane IDs; restarting Mostty invalidates references from an earlier
process. Actions run in the foreground and use the same operations as AppleScript.

## Verification

On Windows, `tools/terminal-integration-acceptance.ps1` launches isolated app
instances with real ConPTY shells and exercises the control interface, directory
inheritance, literal input, invalid IDs, injection opt-out and shell command
preservation. Evidence is written beneath the repository's `tmp/` directory.

`zig build test-macos-automation --global-cache-dir .zig-cache` runs native
acceptance tests in a separate test app with real PTYs and Metal. It exercises
directory inheritance, AppleScript commands, App Intent execution, stale IDs,
literal input and close cancellation. `check-macos-automation` compiles the suite
without opening windows. Unit tests also cover startup-file preservation and
shell launch construction. A GUI session is required for native acceptance.
