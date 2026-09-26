"""Isolate WGL driver/context cost from terminal state (Windows, Python 3)."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
import re
import threading
import time


def api(dll, name, result, *args):
    fn = getattr(dll, name)
    fn.restype, fn.argtypes = result, args
    return fn


class PFD(c.Structure):
    _fields_ = [("size", w.WORD), ("version", w.WORD), ("flags", w.DWORD)] + [
        (name, c.c_ubyte) for name in (
            "pixel_type", "color", "red", "red_shift", "green", "green_shift",
            "blue", "blue_shift", "alpha", "alpha_shift", "accum", "accum_red",
            "accum_green", "accum_blue", "accum_alpha", "depth", "stencil",
            "aux", "layer", "reserved"
        )
    ] + [(name, w.DWORD) for name in ("layer_mask", "visible_mask", "damage_mask")]


class Memory(c.Structure):
    _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [
        (name, c.c_size_t) for name in (
            "peak_working", "working", "peak_paged", "paged", "peak_nonpaged",
            "nonpaged", "pagefile", "peak_pagefile", "private"
        )
    ]


u, g, gl, k = (c.WinDLL(n) for n in ("user32", "gdi32", "opengl32", "kernel32"))
create = api(u, "CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR,
             w.DWORD, c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, c.c_void_p)
destroy = api(u, "DestroyWindow", w.BOOL, w.HWND)
get_dc = api(u, "GetDC", w.HDC, w.HWND)
release_dc = api(u, "ReleaseDC", c.c_int, w.HWND, w.HDC)
choose = api(g, "ChoosePixelFormat", c.c_int, w.HDC, c.POINTER(PFD))
set_format = api(g, "SetPixelFormat", w.BOOL, w.HDC, c.c_int, c.POINTER(PFD))
swap = api(g, "SwapBuffers", w.BOOL, w.HDC)
context = api(gl, "wglCreateContext", w.HANDLE, w.HDC)
delete = api(gl, "wglDeleteContext", w.BOOL, w.HANDLE)
current = api(gl, "wglMakeCurrent", w.BOOL, w.HDC, w.HANDLE)
proc_address = api(gl, "wglGetProcAddress", c.c_void_p, c.c_char_p)
clear = api(gl, "glClear", None, c.c_uint)
finish = api(gl, "glFinish", None)
memory = api(k, "K32GetProcessMemoryInfo", w.BOOL, w.HANDLE, c.POINTER(Memory), w.DWORD)
process = api(k, "GetCurrentProcess", w.HANDLE)


def check(value):
    if not value:
        raise RuntimeError("WGL probe native call failed")
    return value


def sample(phase):
    m = Memory(cb=c.sizeof(Memory))
    check(memory(process(), c.byref(m), m.cb))
    print(json.dumps(dict(phase=phase, private_mib=round(m.private / 2**20, 2),
                         working_mib=round(m.working / 2**20, 2))), flush=True)


def gl_proc(name, result, *args):
    return c.WINFUNCTYPE(result, *args)(check(proc_address(name.encode())))


def compile_programs(detach):
    create_shader = gl_proc("glCreateShader", c.c_uint, c.c_uint)
    source = gl_proc("glShaderSource", None, c.c_uint, c.c_int, c.POINTER(c.c_char_p), c.c_void_p)
    compile_shader = gl_proc("glCompileShader", None, c.c_uint)
    shader_status = gl_proc("glGetShaderiv", None, c.c_uint, c.c_uint, c.POINTER(c.c_int))
    delete_shader = gl_proc("glDeleteShader", None, c.c_uint)
    create_program = gl_proc("glCreateProgram", c.c_uint)
    attach = gl_proc("glAttachShader", None, c.c_uint, c.c_uint)
    detach_shader = gl_proc("glDetachShader", None, c.c_uint, c.c_uint)
    link = gl_proc("glLinkProgram", None, c.c_uint)
    program_status = gl_proc("glGetProgramiv", None, c.c_uint, c.c_uint, c.POINTER(c.c_int))
    root = Path(__file__).resolve().parents[1] / "src/renderer/shaders/glsl"

    def load(path):
        return re.sub(r'^#include "([^"]+)"', lambda m: load(path.parent / m[1]),
                      path.read_text(encoding="utf-8"), flags=re.MULTILINE)

    programs = []
    for vertex, fragment in (("full_screen", "bg_color"), ("full_screen", "cell_bg"),
                             ("cell_text", "cell_text"), ("image", "image"), ("bg_image", "bg_image")):
        shaders = []
        for kind, file in ((0x8B31, vertex + ".v.glsl"), (0x8B30, fragment + ".f.glsl")):
            shader = check(create_shader(kind))
            data = c.c_char_p(load(root / file).encode())
            source(shader, 1, c.byref(data), None)
            compile_shader(shader)
            status = c.c_int()
            shader_status(shader, 0x8B81, c.byref(status))
            check(status.value)
            shaders.append(shader)
        program = check(create_program())
        for shader in shaders:
            attach(program, shader)
        link(program)
        status = c.c_int()
        program_status(program, 0x8B82, c.byref(status))
        check(status.value)
        for shader in shaders:
            if detach:
                detach_shader(program, shader)
            delete_shader(shader)
        programs.append(program)
    return programs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shaders", action="store_true")
    parser.add_argument("--detach", action="store_true")
    parser.add_argument("--release-compiler", action="store_true")
    parser.add_argument("--core", action="store_true")
    parser.add_argument("--retire-inactive", action="store_true",
                        help="delete each previous context while retaining its window and worker")
    parser.add_argument("--exit-retired-workers", action="store_true",
                        help="also exit workers whose contexts have been retired")
    parser.add_argument("--retain-retired-contexts", action="store_true",
                        help="unbind retired contexts but keep their GL objects alive")
    parser.add_argument("--count", type=int, default=8)
    opts = parser.parse_args()
    if not 1 <= opts.count <= 64:
        parser.error("count must be between 1 and 64")
    if (opts.exit_retired_workers or opts.retain_retired_contexts) and not opts.retire_inactive:
        parser.error("retired worker/context options require --retire-inactive")
    resources, workers, errors, retirees = [], [], [], []
    stop = threading.Event()
    create_core = None
    try:
        sample("baseline")
        for i in range(opts.count):
            hwnd = check(create(0, "STATIC", "WGL memory probe", 0x00CF0000,
                                0, 0, 1200, 800, None, None, None, None))
            resources.append([hwnd, None, None])
            dc = resources[-1][1] = check(get_dc(hwnd))
            pfd = PFD(size=c.sizeof(PFD), version=1, flags=0x25, color=32, alpha=8)
            check(set_format(dc, check(choose(dc, c.byref(pfd))), c.byref(pfd)))
            ctx = resources[-1][2] = check(context(dc))
            if opts.core:
                if create_core is None:
                    check(current(dc, ctx))
                    create_core = gl_proc("wglCreateContextAttribsARB", w.HANDLE,
                                          w.HDC, w.HANDLE, c.POINTER(c.c_int))
                    check(current(None, None))
                attributes = (c.c_int * 7)(0x2091, 4, 0x2092, 3, 0x9126, 1, 0)
                replacement = check(create_core(dc, None, attributes))
                check(delete(ctx))
                ctx = resources[-1][2] = replacement
            ready = threading.Event()
            retire = threading.Event()
            retired = threading.Event()
            resource = resources[-1]
            retirees.append((retire, retired))

            def render(dc=dc, ctx=ctx, ready=ready, retire=retire,
                       retired=retired, resource=resource):
                try:
                    check(current(dc, ctx))
                    if opts.shaders:
                        compile_programs(opts.detach)
                    if opts.release_compiler:
                        gl_proc("glReleaseShaderCompiler", None)()
                    clear(0x4000)
                    finish()
                    check(swap(dc))
                except Exception as ex:
                    errors.append(str(ex))
                finally:
                    ready.set()
                retire.wait()
                try:
                    check(current(None, None))
                    if not opts.retain_retired_contexts:
                        check(delete(ctx))
                        resource[2] = None
                except Exception as ex:
                    errors.append(str(ex))
                finally:
                    retired.set()
                if not opts.exit_retired_workers:
                    stop.wait()

            thread = threading.Thread(target=render)
            workers.append(thread)
            thread.start()
            if not ready.wait(10):
                raise RuntimeError("WGL probe timed out")
            if errors:
                raise RuntimeError(errors[0])
            if opts.retire_inactive and i > 0:
                retirees[i-1][0].set()
                if not retirees[i-1][1].wait(10):
                    raise RuntimeError("WGL retirement timed out")
                if opts.exit_retired_workers:
                    workers[i-1].join(10)
                    if workers[i-1].is_alive():
                        raise RuntimeError("WGL worker exit timed out")
                if errors:
                    raise RuntimeError(errors[0])
            time.sleep(0.2)
            sample(f"contexts-{i + 1}")
    finally:
        stop.set()
        for retire, _ in retirees:
            retire.set()
        for thread in workers:
            thread.join()
        for hwnd, dc, ctx in reversed(resources):
            if ctx:
                check(delete(ctx))
            if dc:
                release_dc(hwnd, dc)
            destroy(hwnd)
        sample("released")


if __name__ == "__main__":
    main()
