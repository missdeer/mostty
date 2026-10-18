if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1
setlocal commentstring=#\ %s
setlocal iskeyword+=-
setlocal omnifunc=syntaxcomplete#Complete
let b:undo_ftplugin = "setlocal commentstring< iskeyword< omnifunc<"
if !exists('current_compiler')
  compiler mostty
  let b:undo_ftplugin .= ' makeprg< errorformat<'
endif
