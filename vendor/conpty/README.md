# Bundled ConPTY Source

Runtime lookup order:

1. `MOSTTY_CONPTY_DLL`
2. `<Mostty.exe directory>\conpty\conpty.dll`
3. system `CreatePseudoConsole`

## Source

CI downloads the x64 Windows Terminal/OpenConsole ConPTY pair from Microsoft's
official NuGet package:

- `https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY`

Each workflow resolves the highest stable version, excluding prereleases, from
the NuGet service index. One preparation job downloads it with bounded retries
and shares the verified pair across all Windows build variants. It extracts:

- `runtimes/win-x64/native/conpty.dll`
- `build/native/runtimes/x64/OpenConsole.exe`

Both binaries must have valid Microsoft Corporation Authenticode signatures.
Every application artifact includes `conpty/manifest.json`, recording the
selected version, download URL, package SHA256 and each binary's SHA256.

These binaries are Windows Terminal/OpenConsole components covered by the
Microsoft Terminal MIT license:

https://github.com/microsoft/terminal/blob/main/LICENSE
