" Mostty config syntax; adapted from Ghostty's Vim resource layout.
if exists("b:current_syntax")
  finish
endif
syn match mosttyComment "^\s*#.*$"
syn keyword mosttyKey background background-blur background-image background-image-fit background-image-opacity background-image-position background-image-repeat background-opacity confirm-close-surface cursor-color cursor-text emoji-font-family env font-codepoint-map font-family font-family-bold font-family-bold-italic font-family-italic font-feature font-ligatures font-size font-style font-style-bold font-style-bold-italic font-style-italic font-synthetic-style foreground fullscreen gpu images-enabled launcher maximize palette render-interval-local-ms render-interval-remote-ms renderer selection-background selection-foreground shell-integration smart-ime tabbar-font-family tabbar-font-size theme
syn match mosttyColor "#\x\{6\}\>"
syn match mosttyNumber "\<\d\+\(\.\d\+\)\?\>"
syn keyword mosttyBoolean true false none
hi def link mosttyComment Comment
hi def link mosttyKey Keyword
hi def link mosttyColor Constant
hi def link mosttyNumber Number
hi def link mosttyBoolean Boolean
let b:current_syntax = "mostty"
