# Adapted from Ghostty's bundled shell integration for Mostty.
# SSH/terminfo wrappers are omitted; Mostty uses xterm-256color.
# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

if not set -q MOSTTY_RESOURCES_DIR; or test -z "$MOSTTY_RESOURCES_DIR"
    return
end

function mostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q MOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$MOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase MOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function mostty_exit -d "exit the shell integration setup"
    functions -e mostty_restore_xdg_data_dir
    functions -e mostty_exit
    return
end

# We always try to restore the XDG data dir
mostty_restore_xdg_data_dir

# If we aren't interactive or we've already run, don't run.
if not status --is-interactive; or set -q __mostty_integrated
    mostty_exit
    return
end
set -g __mostty_integrated 1

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __mostty_setup --on-event fish_prompt -d "Setup mostty integration"
    functions -e __mostty_setup

    set --local features (string split , $MOSTTY_SHELL_FEATURES)

    # Parse the fish version for feature detection.
    # Default to 0.0 if version is unavailable or malformed.
    set -l fish_major 0
    set -l fish_minor 0
    if set -q version[1]
        set -l fish_ver (string match -r '(\d+)\.(\d+)' -- $version[1])
        if set -q fish_ver[2]; and test -n "$fish_ver[2]"
            set fish_major "$fish_ver[2]"
        end
        if set -q fish_ver[3]; and test -n "$fish_ver[3]"
            set fish_minor "$fish_ver[3]"
        end
    end

    # Our OSC133A (prompt start) sequence. If we're using Fish >= 4.1
    # then it supports click_events so we enable that.
    set -g __mostty_prompt_start_mark "\e]133;A\a"
    if test "$fish_major" -gt 4; or test "$fish_major" -eq 4 -a "$fish_minor" -ge 1
        set -g __mostty_prompt_start_mark "\e]133;A;click_events=1\a"
    end

    if string match -q 'cursor*' -- $features
        set -l cursor 5                                   # blinking bar
        contains cursor:steady $features && set cursor 6  # steady bar

        # Change the cursor to a beam on prompt.
        function __mostty_set_cursor_beam --on-event fish_prompt -V cursor -d "Set cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[$cursor q"
            end
        end
        function __mostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[0 q"
            end
        end
    end

    # Add Mostty binary to PATH if the path feature is enabled
    if contains path $features; and test -n "$MOSTTY_BIN_DIR"
        fish_add_path --global --path --append "$MOSTTY_BIN_DIR"
    end

    # Setup prompt marking
    function __mostty_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__mostty_prompt_state" != prompt-start
            echo -en "\e]133;D\a"
        end

        set --global __mostty_prompt_state prompt-start
        echo -en $__mostty_prompt_start_mark
    end

    function __mostty_mark_output_start --on-event fish_preexec
        set --global __mostty_prompt_state pre-exec
        echo -en "\e]133;C\a"
    end

    function __mostty_mark_output_end --on-event fish_postexec
        set --global __mostty_prompt_state post-exec
        echo -en "\e]133;D;$status\a"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        printf \e\]7\;file://%s%s\a $hostname (string escape --style=url $PWD)
    end


    # The shared VT core clears semantic prompts when it reflows on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if string match -q 'cursor*' -- $features
        __mostty_set_cursor_beam
    end
    __mostty_mark_prompt_start
    __update_cwd_osc
end

mostty_exit
