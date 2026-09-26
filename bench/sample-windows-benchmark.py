"""Sample the main thread of a newly launched x64 benchmark, resolving PDB symbols.

This is a wall-clock leaf-instruction sampler, not ETW CPU or inclusive-stack
profiling. Suspension perturbs execution: never report its run as throughput.
Only the child launched here is suspended, and it is resumed in a finally block.
"""
import argparse
from collections import Counter
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
from pathlib import Path
import subprocess
import time


def api(dll, name, result, *args):
    fn = getattr(dll, name)
    fn.restype, fn.argtypes = result, args
    return fn


class ThreadEntry(c.Structure):
    _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("id", w.DWORD),
                ("owner", w.DWORD), ("priority", w.LONG),
                ("delta", w.LONG), ("flags", w.DWORD)]


class Symbol(c.Structure):
    _fields_ = [("size", w.ULONG), ("type", w.ULONG), ("reserved", c.c_ulonglong * 2),
                ("index", w.ULONG), ("symbol_size", w.ULONG), ("base", c.c_ulonglong),
                ("flags", w.ULONG), ("value", c.c_ulonglong), ("address", c.c_ulonglong),
                ("register", w.ULONG), ("scope", w.ULONG), ("tag", w.ULONG),
                ("name_len", w.ULONG), ("max_name", w.ULONG), ("name", c.c_char * 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    opts = parser.parse_args()
    command = opts.command[1:] if opts.command[:1] == ['--'] else opts.command
    if not command or c.sizeof(c.c_void_p) != 8:
        parser.error('Provide a command and use x64 Python')
    k, d = c.WinDLL('kernel32', use_last_error=True), c.WinDLL('dbghelp', use_last_error=True)
    timer = c.WinDLL('winmm')
    timer.timeBeginPeriod(1)
    snap = api(k, 'CreateToolhelp32Snapshot', w.HANDLE, w.DWORD, w.DWORD)
    first = api(k, 'Thread32First', w.BOOL, w.HANDLE, c.POINTER(ThreadEntry))
    next_t = api(k, 'Thread32Next', w.BOOL, w.HANDLE, c.POINTER(ThreadEntry))
    close = api(k, 'CloseHandle', w.BOOL, w.HANDLE)
    open_t = api(k, 'OpenThread', w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
    suspend = api(k, 'SuspendThread', w.DWORD, w.HANDLE)
    resume = api(k, 'ResumeThread', w.DWORD, w.HANDLE)
    context = api(k, 'GetThreadContext', w.BOOL, w.HANDLE, c.c_void_p)
    sym_init = api(d, 'SymInitialize', w.BOOL, w.HANDLE, c.c_char_p, w.BOOL)
    sym_addr = api(d, 'SymFromAddr', w.BOOL, w.HANDLE, c.c_ulonglong, c.POINTER(c.c_ulonglong), c.c_void_p)
    sym_clean = api(d, 'SymCleanup', w.BOOL, w.HANDLE)
    # CONTEXT_AMD64 control fields: ContextFlags at 48, Rip at 248.
    storage = c.create_string_buffer(1232 + 15)
    address = (c.addressof(storage) + 15) & ~15
    c.c_uint32.from_address(address + 48).value = 0x100001
    child = subprocess.Popen(command, creationflags=0x4 | 0x08000000,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    thread = None
    symbols = False
    counts = Counter()
    try:
        snapshot = snap(4, 0)
        if snapshot == c.c_void_p(-1).value:
            raise c.WinError(c.get_last_error())
        try:
            entry = ThreadEntry(size=c.sizeof(ThreadEntry))
            valid = first(snapshot, c.byref(entry))
            while valid:
                if entry.owner == child.pid:
                    thread = open_t(0x2 | 0x8 | 0x40, False, entry.id)
                    break
                valid = next_t(snapshot, c.byref(entry))
        finally:
            close(snapshot)
        if not thread:
            raise RuntimeError('Could not open benchmark main thread')
        # Let the loader establish the module list before DbgHelp invades.
        resume(thread)
        time.sleep(0.03)
        symbols = bool(sym_init(int(child._handle), str(Path(command[0]).resolve().parent).encode(), True))
        if not symbols:
            raise c.WinError(c.get_last_error())
        start = time.perf_counter()
        while child.poll() is None:
            if time.perf_counter() - start > 120:
                raise RuntimeError('Benchmark exceeded 120 second sampling bound')
            if suspend(thread) == 0xffffffff:
                break
            try:
                if context(thread, address):
                    counts[c.c_uint64.from_address(address + 248).value] += 1
            finally:
                resume(thread)
            time.sleep(0.001)
        result = Counter()
        for ip, count in counts.items():
            buf = c.create_string_buffer(c.sizeof(Symbol) + 2048)
            info = Symbol.from_buffer(buf)
            info.size, info.max_name = c.sizeof(Symbol), 2048
            displacement = c.c_ulonglong()
            name = hex(ip)
            if sym_addr(int(child._handle), ip, c.byref(displacement), buf):
                name = c.string_at(c.addressof(buf) + Symbol.name.offset, info.name_len).decode(errors='replace')
            result[name] += count
        Path(opts.output).write_text(json.dumps(dict(command=command, exit_code=child.wait(),
            executable_sha256=hashlib.sha256(Path(command[0]).read_bytes()).hexdigest(),
            method='1 ms requested wall-clock leaf samples; suspension perturbs execution; no inline attribution',
            samples=sum(counts.values()), functions=result.most_common()), indent=2) + '\n', encoding='utf-8')
        if child.returncode:
            raise RuntimeError(f'Benchmark exited with {child.returncode}; profile is not a successful run')
    finally:
        timer.timeEndPeriod(1)
        if symbols:
            sym_clean(int(child._handle))
        if thread:
            resume(thread)
            close(thread)
        if child.poll() is None:
            child.terminate()
            child.wait()


if __name__ == '__main__':
    main()
