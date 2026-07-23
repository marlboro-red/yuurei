# defterm proxy/stub

`ITerminalHandoff.idl` is Microsoft's published default-terminal handoff
interface (MIT, from microsoft/terminal `src/host/proxy`). When yuurei is
the Windows default terminal, the inbox conhost passes the PTY pipes and
process handles over COM; the `system_handle` NDR marshaling those
parameters use requires a midl-generated proxy/stub DLL registered on
both sides. `defterm.zig` registers it per-user (HKCU).

`yuurei-defterm-proxy.dll` is prebuilt (same policy as ../conpty) from
the midl-generated sources in ./generated. To regenerate — needs the
Windows SDK `midl.exe` and MSVC `cl.exe`:

    cd generated
    midl /target NT100 /env x64 /h ITerminalHandoff.h ^
         /iid ITerminalHandoff_i.c /proxy ITerminalHandoff_p.c ^
         /dlldata dlldata.c ..\ITerminalHandoff.idl
    cl /O2 /DWIN32 /D_WINDOWS /DREGISTER_PROXY_DLL /LD ^
       dlldata.c ITerminalHandoff_i.c ITerminalHandoff_p.c ^
       /Fe:yuurei-defterm-proxy.dll ^
       /link rpcrt4.lib ole32.lib oleaut32.lib uuid.lib kernel32.lib ^
       /DEF:proxy.def

The proxy class CLSID is the first interface's IID
({59D55CCE-FC8A-48B4-ACE8-0A9286C6557F}), midl's default.
