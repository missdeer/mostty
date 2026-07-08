# Bundled ConPTY Source

Runtime lookup order:

1. `MOSTTY_CONPTY_DLL`
2. `<Mostty.exe directory>\conpty\conpty.dll`
3. system `CreatePseudoConsole`

## Source

CI downloads the x64 Windows Terminal/OpenConsole ConPTY pair from the official
Microsoft Terminal release package:

- `https://github.com/microsoft/terminal/releases/download/v1.23.13503.0/Microsoft.Windows.Console.ConPTY.1.23.251216003.nupkg`

The artifact stage extracts:

- `runtimes/win-x64/native/conpty.dll`
- `build/native/runtimes/x64/OpenConsole.exe`

Version:

- FileVersion: `1.23.2512.16003`
- ProductVersion: `1.23.251216003`

SHA256:

- package: `119F8D06969703AA6530A236EB17DB33A7179A6BC35991E9076A7A63CABABFF7`
- `x64/conpty.dll`: `1F5FFD52FF118DB975EEB25BAC0051F4CEFF3E051313FA03A5AFFFA9E75EE502`
- `x64/OpenConsole.exe`: `6B2915A9A91C0738346A6C6A7B3EE2B74E26582B0C92B1B16066E72570DDDD68`

These binaries are Windows Terminal/OpenConsole components covered by the
Microsoft Terminal MIT license:

https://github.com/microsoft/terminal/blob/main/LICENSE
