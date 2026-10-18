# Adapted from Ghostty's bundled shell integration for Mostty.
# SSH/terminfo wrappers are omitted; Mostty uses xterm-256color.
{
  use platform
  use str

  # Clean up XDG_DATA_DIRS by removing MOSTTY_SHELL_INTEGRATION_XDG_DIR
  if (and (has-env MOSTTY_SHELL_INTEGRATION_XDG_DIR) (has-env XDG_DATA_DIRS)) {
    set-env XDG_DATA_DIRS (str:replace $E:MOSTTY_SHELL_INTEGRATION_XDG_DIR":" "" $E:XDG_DATA_DIRS)
    unset-env MOSTTY_SHELL_INTEGRATION_XDG_DIR
  }

  # List of enabled shell integration features
  var features = [(str:split ',' $E:MOSTTY_SHELL_FEATURES)]

  # State tracking for semantic prompt sequences
  # Values: 'prompt-start', 'pre-exec', 'post-exec'
  fn set-prompt-state {|new| set-env __mostty_prompt_state $new }

  fn mark-prompt-start {
    if (not-eq $E:__mostty_prompt_state 'prompt-start') {
      printf "\e]133;D;aid="$pid"\a"
    }
    set-prompt-state 'prompt-start'
    printf "\e]133;A;aid="$pid"\a"
  }

  fn mark-output-start {|_|
    set-prompt-state 'pre-exec'
    printf "\e]133;C\a"
  }

  fn mark-output-end {|cmd-info|
    set-prompt-state 'post-exec'

    var exit-status = 0

    # in case of error: retrieve exit status,
    # unless does not exist (= builtin function failure), then default to 1
    if (not-eq $nil $cmd-info[error]) {
      set exit-status = 1

      if (has-key $cmd-info[error] reason) {
        if (has-key $cmd-info[error][reason] exit-status) {
          set exit-status = $cmd-info[error][reason][exit-status]
        }
      }
    }

    printf "\e]133;D;"$exit-status";aid="$pid"\a"
  }

  # NOTE: OSC 133;B (end of prompt, start of input) cannot be reliably
  # implemented at the script level in Elvish. The prompt function's output is
  # escaped, and writing to /dev/tty has timing issues because Elvish renders
  # its prompts on a background thread. Full semantic prompt support requires a
  # native implementation: https://github.com/elves/elvish/pull/1917

  defer {
    mark-prompt-start
  }

  set edit:before-readline = (conj $edit:before-readline $mark-prompt-start~)
  set edit:after-readline  = (conj $edit:after-readline $mark-output-start~)
  set edit:after-command   = (conj $edit:after-command $mark-output-end~)

  if (str:contains $E:MOSTTY_SHELL_FEATURES "cursor") {
    var cursor = "5"    # blinking bar
    if (has-value $features cursor:steady) {
      set cursor = "6"  # steady bar
    }

    fn beam  { printf "\e["$cursor" q" }
    fn reset { printf "\e[0 q" }
    set edit:before-readline = (conj $edit:before-readline $beam~)
    set edit:after-readline  = (conj $edit:after-readline {|_| reset })
  }
  if (and (has-value $features path) (has-env MOSTTY_BIN_DIR)) {
    if (not (has-value $paths $E:MOSTTY_BIN_DIR)) {
        set paths = [$@paths $E:MOSTTY_BIN_DIR]
    }
  }
  # Report changes to the current directory.
  fn report-pwd { printf "\e]7;kitty-shell-cwd://%s%s\a" (platform:hostname) $pwd }
  set after-chdir = (conj $after-chdir {|_| report-pwd })
  report-pwd
}
