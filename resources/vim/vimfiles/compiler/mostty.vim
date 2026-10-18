if exists('current_compiler')
  finish
endif
let current_compiler = 'mostty'
CompilerSet makeprg=Mostty\ +validate-config\ --config-file=%:S
CompilerSet errorformat=%*[^:]:\ config:\ %f:%l:\ %m,%f:%l:%m,%*[^:]:\ config:\ %m,%-G%.%#
