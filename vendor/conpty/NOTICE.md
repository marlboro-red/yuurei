# Vendored ConPTY binaries

`conpty.dll` and `OpenConsole.exe` are built from the
[microsoft/terminal](https://github.com/microsoft/terminal) project and
are licensed under the MIT License (Copyright (c) Microsoft Corporation).

These copies were obtained from the
[WezTerm](https://github.com/wez/wezterm) project's vendored
distribution (`assets/windows/conhost/`), which redistributes the same
binaries under the same license.

## Why they're here

yuurei prefers a vendored `conpty.dll` next to its executable over the
in-box Windows ConPTY (see `src/os/windows.zig`). The Windows-shipped
conhost lags the microsoft/terminal project by years; the vendored pair
provides newer, faster pseudoconsole behavior and is the same approach
Windows Terminal itself and WezTerm use. If these files are removed,
yuurei falls back to the OS ConPTY automatically.

## MIT License (microsoft/terminal)

Copyright (c) Microsoft Corporation. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
