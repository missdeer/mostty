export MOSTTY_STARTUP="${MOSTTY_STARTUP}:rc"
PS1='mostty-test> '
HISTFILE=/dev/null
SAVEHIST=0
if [[ -n ${MOSTTY_TEST_ZLE_READY-} ]]; then
    autoload -Uz add-zle-hook-widget
    _mostty_test_zle_ready() {
        : > "$MOSTTY_TEST_ZLE_READY"
    }
    add-zle-hook-widget line-init _mostty_test_zle_ready
fi
