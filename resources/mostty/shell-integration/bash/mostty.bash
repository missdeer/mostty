# Adapted from Ghostty's bundled shell integration for Mostty.
# SSH/terminfo wrappers are omitted; Mostty uses xterm-256color.
# Parts of this script are based on Kitty's bash integration. Kitty is
# distributed under GPLv3, so this file is also distributed under GPLv3.
# The license header is reproduced below:
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# We need to be in interactive mode to proceed.
if [[ "$-" != *i* ]]; then builtin return; fi

if [[ -n ${__mostty_loaded:-} ]]; then builtin return; fi
__mostty_loaded=1
if [[ -r "$MOSTTY_RESOURCES_DIR/../bash-completion/completions/Mostty" ]]; then
  builtin source "$MOSTTY_RESOURCES_DIR/../bash-completion/completions/Mostty"
fi

# When automatic shell integration is active, we were started in POSIX
# mode and need to manually recreate the bash startup sequence.
if [ -n "$MOSTTY_BASH_INJECT" ]; then
  # Store a temporary copy of our startup flags and unset these global
  # environment variables so we can safely handle reentrancy.
  builtin declare __mostty_bash_flags="$MOSTTY_BASH_INJECT"
  builtin unset ENV MOSTTY_BASH_INJECT

  # Restore an existing ENV that was replaced by the shell integration code.
  if [[ -n "$MOSTTY_BASH_ENV" ]]; then
    builtin export ENV=$MOSTTY_BASH_ENV
    builtin unset MOSTTY_BASH_ENV
  fi

  # Restore bash's default 'posix' behavior. Also reset 'inherit_errexit',
  # which doesn't happen as part of the 'posix' reset.
  builtin set +o posix
  builtin shopt -u inherit_errexit 2>/dev/null

  # Unexport HISTFILE if it was set by the shell integration code.
  if [[ -n "$MOSTTY_BASH_UNEXPORT_HISTFILE" ]]; then
    builtin export -n HISTFILE
    builtin unset MOSTTY_BASH_UNEXPORT_HISTFILE
  fi

  # Manually source the startup files. See INVOCATION in bash(1) and
  # run_startup_files() in shell.c in the Bash source code.
  if builtin shopt -q login_shell; then
    if [[ $__mostty_bash_flags != *"--noprofile"* ]]; then
      [ -r /etc/profile ] && builtin source "/etc/profile"
      for __mostty_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        [ -r "$__mostty_rcfile" ] && {
          builtin source "$__mostty_rcfile"
          break
        }
      done
    fi
  else
    if [[ $__mostty_bash_flags != *"--norc"* ]]; then
      # The location of the system bashrc is determined at bash build
      # time via -DSYS_BASHRC and can therefore vary across distros:
      #  Arch, Debian, Ubuntu use /etc/bash.bashrc
      #  Fedora uses /etc/bashrc sourced from ~/.bashrc instead of SYS_BASHRC
      #  Void Linux uses /etc/bash/bashrc
      #  Nixos uses /etc/bashrc
      for __mostty_rcfile in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
        [ -r "$__mostty_rcfile" ] && {
          builtin source "$__mostty_rcfile"
          break
        }
      done
      if [[ -z "$MOSTTY_BASH_RCFILE" ]]; then MOSTTY_BASH_RCFILE="$HOME/.bashrc"; fi
      [ -r "$MOSTTY_BASH_RCFILE" ] && builtin source "$MOSTTY_BASH_RCFILE"
    fi
  fi

  builtin unset __mostty_rcfile
  builtin unset __mostty_bash_flags
  builtin unset MOSTTY_BASH_RCFILE
fi

# Add Mostty binary to PATH if the path feature is enabled
if [[ "$MOSTTY_SHELL_FEATURES" == *"path"* && -n "$MOSTTY_BIN_DIR" ]]; then
  if [[ ":$PATH:" != *":$MOSTTY_BIN_DIR:"* ]]; then
    export PATH="$PATH:$MOSTTY_BIN_DIR"
  fi
fi

# This is set to 1 when we're executing a command so that we don't
# send prompt marks multiple times.
_mostty_executing=""
_mostty_last_reported_cwd=""

function __mostty_precmd() {
  local ret="$?"
  if test "$_mostty_executing" != "0"; then
    _MOSTTY_SAVE_PS1="$PS1"
    _MOSTTY_SAVE_PS2="$PS2"

    # Use 133;P (not 133;A) inside PS1 to avoid fresh-line behavior on
    # readline redraws (e.g., vi mode switches, Ctrl-L). The initial
    # 133;A with fresh-line is emitted once via printf below.
    PS1='\[\e]133;P;k=i\a\]'$PS1'\[\e]133;B\a\]'
    PS2='\[\e]133;P;k=s\a\]'$PS2'\[\e]133;B\a\]'

    # Bash doesn't redraw the leading lines in a multiline prompt so we mark
    # the start of each line (after each newline) as a secondary prompt. This
    # correctly handles multiline prompts by setting the first to primary and
    # the subsequent lines to secondary.
    #
    # We only replace the \n prompt escape, not literal newlines ($'\n'),
    # because literal newlines may appear inside $(...) command substitutions
    # where inserting escape sequences would break shell syntax.
    if [[ "$PS1" == *"\n"* ]]; then
      PS1="${PS1//\\n/\\n$'\\[\\e]133;P;k=s\\a\\]'}"
    fi

    # Cursor
    if [[ "$MOSTTY_SHELL_FEATURES" == *"cursor"* ]]; then
      builtin local cursor=5  # blinking bar
      [[ "$MOSTTY_SHELL_FEATURES" == *"cursor:steady"* ]] && cursor=6  # steady bar

      [[ "$PS1" != *"\[\e[${cursor} q\]"* ]] && PS1=$PS1"\[\e[${cursor} q\]"
      [[ "$PS0" != *'\[\e[0 q\]'* ]] && PS0=$PS0'\[\e[0 q\]' # reset
    fi

    # Title (working directory)
    if [[ "$MOSTTY_SHELL_FEATURES" == *"title"* ]]; then
      PS1=$PS1'\[\e]2;\w\a\]'
    fi
  fi

  if test "$_mostty_executing" != ""; then
    # End of current command. Report its status.
    builtin printf "\e]133;D;%s;aid=%s\a" "$ret" "$BASHPID"
  fi

  # Fresh line and start of prompt.
  builtin printf "\e]133;A;redraw=last;cl=line;aid=%s\a" "$BASHPID"

  # unfortunately bash provides no hooks to detect cwd changes
  # in particular this means cwd reporting will not happen for a
  # command like cd /test && cat. PS0 is evaluated before cd is run.
  if [[ "$_mostty_last_reported_cwd" != "$PWD" ]]; then
    _mostty_last_reported_cwd="$PWD"
    builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"
  fi

  _mostty_executing=0
}

function __mostty_preexec() {
  builtin local cmd="$1"

  PS1="$_MOSTTY_SAVE_PS1"
  PS2="$_MOSTTY_SAVE_PS2"

  # Title (current command)
  if [[ -n $cmd && "$MOSTTY_SHELL_FEATURES" == *"title"* ]]; then
    builtin printf "\e]2;%s\a" "${cmd//[[:cntrl:]]/}"
  fi

  # End of input, start of output.
  builtin printf "\e]133;C;\a"
  _mostty_executing=1
}

if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  __mostty_preexec_hook() {
    builtin local cmd
    cmd=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1)
    cmd="${cmd#*[[:digit:]][* ] }"  # remove leading history number
    [[ -n "$cmd" ]] && __mostty_preexec "$cmd"
  }

  # Use function substitution in 5.3+. Otherwise, use command substitution.
  # Any output (including escape sequences) goes to the terminal.
  # Only define if not already set (allows re-sourcing).
  if [[ -z "${__mostty_ps0+x}" ]]; then
    if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
      # shellcheck disable=SC2016
      builtin readonly __mostty_ps0='${ __mostty_preexec_hook; }'
    else
      # shellcheck disable=SC2016
      builtin readonly __mostty_ps0='$(__mostty_preexec_hook >/dev/tty)'
    fi
  fi

  __mostty_hook() {
    builtin local ret=$?
    __mostty_precmd "$ret"
    if [[ "$PS0" != *"$__mostty_ps0"* ]]; then
      PS0=$PS0"${__mostty_ps0}"
    fi
  }

  # Append our hook to PROMPT_COMMAND, preserving its existing type.
  # shellcheck disable=SC2128,SC2178,SC2179
  if [[ ";${PROMPT_COMMAND[*]:-};" != *";__mostty_hook;"* ]]; then
    if [[ -z "${PROMPT_COMMAND[*]}" ]]; then
      if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
        PROMPT_COMMAND=(__mostty_hook)
      else
        PROMPT_COMMAND="__mostty_hook"
      fi
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a "* ]]; then
      PROMPT_COMMAND+=(__mostty_hook)
    else
      [[ "${PROMPT_COMMAND}" =~ \;[[:space:]]*$ ]] || PROMPT_COMMAND+=";"
      PROMPT_COMMAND+=" __mostty_hook"
    fi
  fi
else
  builtin source "$(dirname -- "${BASH_SOURCE[0]}")/bash-preexec.sh"
  preexec_functions+=(__mostty_preexec)
  precmd_functions+=(__mostty_precmd)
fi
