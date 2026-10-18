# Nushell implements the terminal protocols natively. Keep its own startup
# hooks, cursor handling and prompt rendering rather than wrapping them.
if ($env.MOSTTY_RESOURCES_DIR? | is-not-empty) {
  $env.config.shell_integration.osc2 = true
  $env.config.shell_integration.osc7 = true
  $env.config.shell_integration.osc133 = true
  if ($env.MOSTTY_BIN_DIR? | is-not-empty) {
    $env.PATH = ($env.PATH | append $env.MOSTTY_BIN_DIR | uniq)
  }
}
