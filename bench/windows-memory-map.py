"""Read-only x64 Windows process commit/stack inventory. No memory contents saved."""
import argparse
from collections import Counter, defaultdict
import ctypes as c
from ctypes import wintypes as w
import json


def api(dll, name, result, *args):
    fn = getattr(dll, name)
    fn.restype, fn.argtypes = result, args
    return fn


class MBI(c.Structure):
    _fields_ = [("base", c.c_void_p), ("allocation", c.c_void_p),
                ("allocation_protect", w.DWORD), ("partition", w.WORD),
                ("size", c.c_size_t), ("state", w.DWORD),
                ("protect", w.DWORD), ("type", w.DWORD)]


class ThreadEntry(c.Structure):
    _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("id", w.DWORD),
                ("owner", w.DWORD), ("priority", w.LONG),
                ("delta", w.LONG), ("flags", w.DWORD)]


class ThreadBasic(c.Structure):
    _fields_ = [("exit", w.LONG), ("teb", c.c_void_p),
                ("pid", c.c_void_p), ("tid", c.c_void_p),
                ("affinity", c.c_size_t), ("priority", w.LONG), ("base_priority", w.LONG)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    opts = parser.parse_args()
    if c.sizeof(c.c_void_p) != 8:
        parser.error("Use 64-bit Python for an x64 target")
    k, nt = c.WinDLL("kernel32", use_last_error=True), c.WinDLL("ntdll")
    open_process = api(k, "OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
    close = api(k, "CloseHandle", w.BOOL, w.HANDLE)
    query = api(k, "VirtualQueryEx", c.c_size_t, w.HANDLE, c.c_void_p, c.POINTER(MBI), c.c_size_t)
    read = api(k, "ReadProcessMemory", w.BOOL, w.HANDLE, c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p)
    snapshot = api(k, "CreateToolhelp32Snapshot", w.HANDLE, w.DWORD, w.DWORD)
    first = api(k, "Thread32First", w.BOOL, w.HANDLE, c.POINTER(ThreadEntry))
    next_thread = api(k, "Thread32Next", w.BOOL, w.HANDLE, c.POINTER(ThreadEntry))
    open_thread = api(k, "OpenThread", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
    thread_info = api(nt, "NtQueryInformationThread", w.LONG, w.HANDLE, c.c_int, c.c_void_p, w.ULONG, c.c_void_p)
    thread_description = api(k, "GetThreadDescription", w.LONG, w.HANDLE, c.POINTER(c.c_void_p))
    local_free = api(k, "LocalFree", c.c_void_p, c.c_void_p)
    process = open_process(0x410, False, opts.pid)
    if not process:
        raise c.WinError(c.get_last_error())
    try:
        stacks, errors = [], []
        snap = snapshot(4, 0)
        if snap == c.c_void_p(-1).value:
            raise c.WinError(c.get_last_error())
        try:
            entry = ThreadEntry(size=c.sizeof(ThreadEntry))
            valid = first(snap, c.byref(entry))
            while valid:
                if entry.owner == opts.pid:
                    thread = open_thread(0x40 | 0x800, False, entry.id)
                    if thread:
                        try:
                            info = ThreadBasic()
                            tib = (c.c_size_t * 3)()
                            if thread_info(thread, 0, c.byref(info), c.sizeof(info), None) >= 0 and read(process, info.teb, tib, c.sizeof(tib), None):
                                name_ptr = c.c_void_p()
                                name = ""
                                if thread_description(thread, c.byref(name_ptr)) >= 0 and name_ptr:
                                    name = c.wstring_at(name_ptr)
                                    local_free(name_ptr)
                                region = MBI()
                                if query(process, tib[1] - 1, c.byref(region), c.sizeof(region)):
                                    stacks.append(dict(tid=entry.id, name=name, allocation=region.allocation,
                                                       stack_base=tib[1], stack_limit=tib[2]))
                            else:
                                errors.append(dict(tid=entry.id, operation="query_tib"))
                        finally:
                            close(thread)
                    else:
                        errors.append(dict(tid=entry.id, operation="open_thread"))
                valid = next_thread(snap, c.byref(entry))
        finally:
            close(snap)

        allocations = defaultdict(lambda: dict(committed=0, reserved=0, types=Counter(), protections=Counter()))
        address = 0
        totals = Counter()
        while True:
            region = MBI()
            if not query(process, address, c.byref(region), c.sizeof(region)):
                break
            if region.state in (0x1000, 0x2000):
                a = allocations[region.allocation]
                if region.state == 0x1000:
                    a["committed"] += region.size
                    a["types"][hex(region.type)] += region.size
                    a["protections"][hex(region.protect)] += region.size
                    totals[hex(region.type)] += region.size
                else:
                    a["reserved"] += region.size
            following = (region.base or 0) + region.size
            if following <= address:
                raise RuntimeError("VirtualQueryEx did not advance")
            address = following
        stack_addresses = {s["allocation"] for s in stacks}
        for stack in stacks:
            a = allocations[stack["allocation"]]
            stack.update(committed=a["committed"], reserved=a["reserved"])
        private_sizes = Counter()
        largest = []
        for base, a in allocations.items():
            private = a["types"].get("0x20000", 0)
            if private and base not in stack_addresses:
                private_sizes[private] += 1
                largest.append(dict(base=base, **a))
        print(json.dumps(dict(pid=opts.pid, committed_by_type=dict(totals),
                              stack_committed=sum(s["committed"] for s in stacks),
                              stacks=stacks, errors=errors,
                              private_allocation_sizes=sorted(private_sizes.items(), reverse=True),
                              largest_nonstack_private=sorted(largest, key=lambda a: a["committed"], reverse=True)[:40]), indent=2))
    finally:
        close(process)


if __name__ == "__main__":
    main()
