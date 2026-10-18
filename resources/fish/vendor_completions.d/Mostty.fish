for cmd in Mostty mostty
    complete -c $cmd -f
    complete -c $cmd -l help -d 'Show help'
    complete -c $cmd -l font-size -x -d 'Font size'
    complete -c $cmd -l background-opacity -x -d 'Background opacity'
    complete -c $cmd -l background-blur -x -a 'true false' -d 'Enable background blur'
    complete -c $cmd -a '+list-themes' -d 'List theme names'
    complete -c $cmd -a '+validate-config' -d 'Validate configuration'
    complete -c $cmd -l config-file -r -F -n 'contains -- +validate-config (commandline -opc)' -d 'Configuration to validate'
    if test (uname) != Darwin
        complete -c $cmd -l ttf -r -F -d 'TrueType font file'
        complete -c $cmd -l renderer -x -a 'd3d11 d3d12 opengl pure-opengl vulkan native-vulkan' -d 'Renderer backend'
    end
end
