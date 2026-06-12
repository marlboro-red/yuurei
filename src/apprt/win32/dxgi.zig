//! Minimal hand-written D3D11/DXGI COM bindings and a Presenter that
//! gives a GL-rendered surface flip-model presentation.
//!
//! Why: WGL SwapBuffers presents through DWM's legacy redirected
//! surface (the "blt model"), costing 1-2 frames of compositor
//! latency. A DXGI flip-model swapchain is the low-latency path the
//! OS offers (what Windows Terminal uses). The renderer keeps drawing
//! plain GL into its default framebuffer; each frame is shared into
//! the swapchain's backbuffer with WGL_NV_DX_interop2 and presented.
//!
//! These bindings follow the hand-written winapi.zig philosophy:
//! only the vtable slots we call, with the layout fixed by the
//! published COM ABI. If anything here fails at runtime the caller
//! falls back to SwapBuffers.
const std = @import("std");
const windows = std.os.windows;
const winapi = @import("winapi.zig");

const log = std.log.scoped(.dxgi);

pub const HRESULT = i32;

fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

const IID_IDXGIDevice: GUID = .{
    .a = 0x54ec77fa,
    .b = 0x1377,
    .c = 0x44e6,
    .d = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
};
const IID_IDXGIDevice1: GUID = .{
    .a = 0x77db970f,
    .b = 0x6276,
    .c = 0x48ba,
    .d = .{ 0xba, 0x28, 0x07, 0x01, 0x43, 0xb4, 0x39, 0x2c },
};
const IID_IDXGISwapChain2: GUID = .{
    .a = 0xa8be2ac4,
    .b = 0x199f,
    .c = 0x4946,
    .d = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 },
};
const IID_ID3D11Texture2D: GUID = .{
    .a = 0x6f15aaf2,
    .b = 0xd208,
    .c = 0x4e89,
    .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

/// IUnknown: the leading three slots of every COM vtable.
fn Unknown(comptime Self: type) type {
    return extern struct {
        QueryInterface: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Self) callconv(.winapi) u32,
        Release: *const fn (*Self) callconv(.winapi) u32,
    };
}

/// IDXGIObject: four slots after IUnknown, none of which we call.
fn DxgiObjectPad(comptime Self: type) type {
    return extern struct {
        SetPrivateData: *const fn (*Self) callconv(.winapi) HRESULT,
        SetPrivateDataInterface: *const fn (*Self) callconv(.winapi) HRESULT,
        GetPrivateData: *const fn (*Self) callconv(.winapi) HRESULT,
        GetParent: *const fn (*Self, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
}

pub const IUnknownAny = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IUnknownAny),
    },

    pub fn release(self: *IUnknownAny) void {
        _ = self.vtable.unknown.Release(self);
    }
};

pub fn releaseAny(ptr: anytype) void {
    const any: *IUnknownAny = @ptrCast(@alignCast(ptr));
    any.release();
}

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32 = 1,
    ArraySize: u32 = 1,
    Format: u32,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    Usage: u32 = 0, // D3D11_USAGE_DEFAULT
    BindFlags: u32,
    CPUAccessFlags: u32 = 0,
    MiscFlags: u32 = 0,
};

const D3D11_BIND_RENDER_TARGET: u32 = 0x20;

fn Pad(comptime Self: type, comptime n: usize) type {
    return [n]*const fn (*Self) callconv(.winapi) void;
}

pub const ID3D11Device = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(ID3D11Device),
        CreateBuffer: *const fn (*ID3D11Device) callconv(.winapi) HRESULT,
        CreateTexture1D: *const fn (*ID3D11Device) callconv(.winapi) HRESULT,
        CreateTexture2D: *const fn (
            *ID3D11Device,
            *const D3D11_TEXTURE2D_DESC,
            ?*const anyopaque, // initial data
            *?*anyopaque, // ID3D11Texture2D out
        ) callconv(.winapi) HRESULT,
        // Dozens of creation methods we never call follow.
    },
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(ID3D11DeviceContext),
        // ID3D11DeviceChild: GetDevice, Get/Set/SetPrivateDataInterface.
        device_child: Pad(ID3D11DeviceContext, 4),
        // ID3D11DeviceContext slots 7..46 (VSSetConstantBuffers
        // through CopySubresourceRegion), unused.
        pad: Pad(ID3D11DeviceContext, 40),
        CopyResource: *const fn (
            *ID3D11DeviceContext,
            *anyopaque, // dst ID3D11Resource
            *anyopaque, // src ID3D11Resource
        ) callconv(.winapi) void,
    },
};

pub const IDXGIDevice = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IDXGIDevice),
        object: DxgiObjectPad(IDXGIDevice),
        GetAdapter: *const fn (*IDXGIDevice, *?*IDXGIAdapter) callconv(.winapi) HRESULT,
        // CreateSurface, QueryResourceResidency, Set/GetGPUThreadPriority follow.
    },
};

pub const IDXGIDevice1 = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IDXGIDevice1),
        object: DxgiObjectPad(IDXGIDevice1),
        // IDXGIDevice
        GetAdapter: *const fn (*IDXGIDevice1) callconv(.winapi) HRESULT,
        CreateSurface: *const fn (*IDXGIDevice1) callconv(.winapi) HRESULT,
        QueryResourceResidency: *const fn (*IDXGIDevice1) callconv(.winapi) HRESULT,
        SetGPUThreadPriority: *const fn (*IDXGIDevice1) callconv(.winapi) HRESULT,
        GetGPUThreadPriority: *const fn (*IDXGIDevice1) callconv(.winapi) HRESULT,
        // IDXGIDevice1
        SetMaximumFrameLatency: *const fn (*IDXGIDevice1, u32) callconv(.winapi) HRESULT,
        GetMaximumFrameLatency: *const fn (*IDXGIDevice1) callconv(.winapi) HRESULT,
    },
};

pub const IDXGIAdapter = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IDXGIAdapter),
        object: DxgiObjectPad(IDXGIAdapter),
    },
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32,
    Height: u32,
    Format: u32,
    Stereo: windows.BOOL = 0,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: u32,
    BufferCount: u32,
    Scaling: u32,
    SwapEffect: u32,
    AlphaMode: u32,
    Flags: u32,
};

pub const IDXGIFactory2 = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IDXGIFactory2),
        object: DxgiObjectPad(IDXGIFactory2),
        // IDXGIFactory
        EnumAdapters: *const fn (*IDXGIFactory2) callconv(.winapi) HRESULT,
        MakeWindowAssociation: *const fn (*IDXGIFactory2, winapi.HWND, u32) callconv(.winapi) HRESULT,
        GetWindowAssociation: *const fn (*IDXGIFactory2) callconv(.winapi) HRESULT,
        CreateSwapChain: *const fn (*IDXGIFactory2) callconv(.winapi) HRESULT,
        CreateSoftwareAdapter: *const fn (*IDXGIFactory2) callconv(.winapi) HRESULT,
        // IDXGIFactory1
        EnumAdapters1: *const fn (*IDXGIFactory2) callconv(.winapi) HRESULT,
        IsCurrent: *const fn (*IDXGIFactory2) callconv(.winapi) windows.BOOL,
        // IDXGIFactory2
        IsWindowedStereoEnabled: *const fn (*IDXGIFactory2) callconv(.winapi) windows.BOOL,
        CreateSwapChainForHwnd: *const fn (
            *IDXGIFactory2,
            *anyopaque, // the device
            winapi.HWND,
            *const DXGI_SWAP_CHAIN_DESC1,
            ?*const anyopaque, // fullscreen desc
            ?*anyopaque, // restrict-to output
            *?*IDXGISwapChain1,
        ) callconv(.winapi) HRESULT,
    },
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IDXGISwapChain1),
        object: DxgiObjectPad(IDXGISwapChain1),
        // IDXGIDeviceSubObject
        GetDevice: *const fn (*IDXGISwapChain1) callconv(.winapi) HRESULT,
        // IDXGISwapChain
        Present: *const fn (*IDXGISwapChain1, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain1, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: *const fn (*IDXGISwapChain1) callconv(.winapi) HRESULT,
        GetFullscreenState: *const fn (*IDXGISwapChain1) callconv(.winapi) HRESULT,
        GetDesc: *const fn (*IDXGISwapChain1) callconv(.winapi) HRESULT,
        ResizeBuffers: *const fn (*IDXGISwapChain1, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT,
    },

    pub fn release(self: *IDXGISwapChain1) void {
        releaseAny(self);
    }
};

pub const IDXGISwapChain2 = extern struct {
    vtable: *const extern struct {
        unknown: Unknown(IDXGISwapChain2),
        object: DxgiObjectPad(IDXGISwapChain2),
        GetDevice: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        Present: *const fn (*IDXGISwapChain2, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        SetFullscreenState: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetFullscreenState: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetDesc: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        ResizeBuffers: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        ResizeTarget: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetContainingOutput: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetFrameStatistics: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetLastPresentCount: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        // IDXGISwapChain1
        GetDesc1: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetFullscreenDesc: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetHwnd: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetCoreWindow: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        Present1: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        IsTemporaryMonoSupported: *const fn (*IDXGISwapChain2) callconv(.winapi) windows.BOOL,
        GetRestrictToOutput: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        SetBackgroundColor: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetBackgroundColor: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        SetRotation: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetRotation: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        // IDXGISwapChain2
        SetSourceSize: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetSourceSize: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        SetMaximumFrameLatency: *const fn (*IDXGISwapChain2, u32) callconv(.winapi) HRESULT,
        GetMaximumFrameLatency: *const fn (*IDXGISwapChain2) callconv(.winapi) HRESULT,
        GetFrameLatencyWaitableObject: *const fn (*IDXGISwapChain2) callconv(.winapi) ?windows.HANDLE,
    },
};

const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
const DXGI_SCALING_STRETCH: u32 = 0;
const DXGI_SCALING_NONE: u32 = 1;
const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
const DXGI_ALPHA_MODE_IGNORE: u32 = 3;
const DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 0x40;

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;

extern "d3d11" fn D3D11CreateDevice(
    pAdapter: ?*anyopaque,
    DriverType: u32,
    Software: ?*anyopaque,
    Flags: u32,
    pFeatureLevels: ?[*]const u32,
    FeatureLevels: u32,
    SDKVersion: u32,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*u32,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

// ---------------------------------------------------------------------
// WGL_NV_DX_interop2 (loaded per GL context; supported by all three
// desktop GPU vendors' GL drivers).

const WGL_ACCESS_WRITE_DISCARD_NV: u32 = 0x2;
pub const GL_RENDERBUFFER: u32 = 0x8D41;

const Interop = struct {
    open: *const fn (?*anyopaque) callconv(.winapi) ?windows.HANDLE,
    close: *const fn (windows.HANDLE) callconv(.winapi) windows.BOOL,
    register: *const fn (windows.HANDLE, *anyopaque, u32, u32, u32) callconv(.winapi) ?windows.HANDLE,
    unregister: *const fn (windows.HANDLE, windows.HANDLE) callconv(.winapi) windows.BOOL,
    lock: *const fn (windows.HANDLE, i32, [*]const windows.HANDLE) callconv(.winapi) windows.BOOL,
    unlock: *const fn (windows.HANDLE, i32, [*]const windows.HANDLE) callconv(.winapi) windows.BOOL,

    fn load() ?Interop {
        return .{
            .open = @ptrCast(winapi.wglGetProcAddress("wglDXOpenDeviceNV") orelse return null),
            .close = @ptrCast(winapi.wglGetProcAddress("wglDXCloseDeviceNV") orelse return null),
            .register = @ptrCast(winapi.wglGetProcAddress("wglDXRegisterObjectNV") orelse return null),
            .unregister = @ptrCast(winapi.wglGetProcAddress("wglDXUnregisterObjectNV") orelse return null),
            .lock = @ptrCast(winapi.wglGetProcAddress("wglDXLockObjectsNV") orelse return null),
            .unlock = @ptrCast(winapi.wglGetProcAddress("wglDXUnlockObjectsNV") orelse return null),
        };
    }
};

// ---------------------------------------------------------------------
// Presenter

/// Flip-model presentation for one GL surface. All methods must be
/// called on the renderer thread with its GL context current.
pub const Presenter = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swapchain: *IDXGISwapChain1,

    interop: Interop,
    interop_device: windows.HANDLE,

    /// The intermediate D3D texture GL renders into. Flip-model
    /// backbuffers rotate every present, so the GL side targets this
    /// stable texture and present() copies it into whichever buffer
    /// is current.
    texture: ?*anyopaque = null,
    interop_object: ?windows.HANDLE = null,

    /// GL names: the renderbuffer aliasing the backbuffer and the FBO
    /// wrapping it (created/destroyed by the caller's GL helper).
    renderbuffer: u32 = 0,
    fbo: u32 = 0,

    width: u32,
    height: u32,

    pub fn init(hwnd: winapi.HWND, width: u32, height: u32) !Presenter {
        const interop = Interop.load() orelse {
            log.info("WGL_NV_DX_interop2 unavailable; using SwapBuffers", .{});
            return error.InteropUnavailable;
        };

        var device: ?*ID3D11Device = null;
        var context: ?*ID3D11DeviceContext = null;
        if (!ok(D3D11CreateDevice(
            null,
            D3D_DRIVER_TYPE_HARDWARE,
            null,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        ))) return error.D3DDeviceFailed;
        errdefer {
            releaseAny(context.?);
            releaseAny(device.?);
        }

        // device -> IDXGIDevice -> adapter -> factory
        var dxgi_dev: ?*anyopaque = null;
        if (!ok(device.?.vtable.unknown.QueryInterface(
            device.?,
            &IID_IDXGIDevice,
            &dxgi_dev,
        ))) return error.NoDxgiDevice;
        const dxgi_device: *IDXGIDevice = @ptrCast(@alignCast(dxgi_dev.?));
        defer releaseAny(dxgi_device);

        var adapter: ?*IDXGIAdapter = null;
        if (!ok(dxgi_device.vtable.GetAdapter(dxgi_device, &adapter)))
            return error.NoAdapter;
        defer releaseAny(adapter.?);

        const IID_IDXGIFactory2: GUID = .{
            .a = 0x50c83a1c,
            .b = 0xe072,
            .c = 0x4c48,
            .d = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
        };
        var factory_ptr: ?*anyopaque = null;
        if (!ok(adapter.?.vtable.object.GetParent(
            adapter.?,
            &IID_IDXGIFactory2,
            &factory_ptr,
        ))) return error.NoFactory;
        const factory: *IDXGIFactory2 = @ptrCast(@alignCast(factory_ptr.?));
        defer releaseAny(factory);

        const desc: DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = @max(1, width),
            .Height = @max(1, height),
            .Format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            // Exact-size buffers; a promotion prerequisite for DWM's
            // hardware overlay (independent flip) path.
            .Scaling = DXGI_SCALING_NONE,
            .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .AlphaMode = DXGI_ALPHA_MODE_IGNORE,
            .Flags = 0,
        };
        var swapchain: ?*IDXGISwapChain1 = null;
        if (!ok(factory.vtable.CreateSwapChainForHwnd(
            factory,
            device.?,
            hwnd,
            &desc,
            null,
            null,
            &swapchain,
        ))) return error.SwapChainFailed;
        errdefer swapchain.?.release();

        // Cap the present queue at one frame. We deliberately do NOT
        // use the frame-latency waitable object: that pattern is for
        // continuous render loops that wait *before* sampling input.
        // Our renderer is event-driven — a wait at frame start would
        // delay a freshly damaged frame by up to a full compose cycle
        // (felt as typing lag). With the device-level cap, Present
        // blocks only when a previous present is still queued, which
        // for sporadic frames is almost never and during bursts is
        // exactly the throttle we want.
        {
            var dev1_ptr: ?*anyopaque = null;
            if (ok(device.?.vtable.unknown.QueryInterface(
                device.?,
                &IID_IDXGIDevice1,
                &dev1_ptr,
            ))) {
                const dev1: *IDXGIDevice1 = @ptrCast(@alignCast(dev1_ptr.?));
                defer releaseAny(dev1);
                _ = dev1.vtable.SetMaximumFrameLatency(dev1, 1);
            }
        }

        const interop_device = interop.open(device.?) orelse {
            log.warn("wglDXOpenDeviceNV failed; using SwapBuffers", .{});
            return error.InteropOpenFailed;
        };

        return .{
            .device = device.?,
            .context = context.?,
            .swapchain = swapchain.?,
            .interop = interop,
            .interop_device = interop_device,
            .width = @max(1, width),
            .height = @max(1, height),
        };
    }

    pub fn deinit(self: *Presenter) void {
        self.releaseBackbuffer();
        _ = self.interop.close(self.interop_device);
        self.swapchain.release();
        releaseAny(self.context);
        releaseAny(self.device);
    }

    /// Create the intermediate texture and register it as the given
    /// GL renderbuffer.
    pub fn acquireBackbuffer(self: *Presenter, renderbuffer: u32) !void {
        if (self.interop_object != null) return;

        const desc: D3D11_TEXTURE2D_DESC = .{
            .Width = self.width,
            .Height = self.height,
            .Format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .BindFlags = D3D11_BIND_RENDER_TARGET,
        };
        var tex: ?*anyopaque = null;
        if (!ok(self.device.vtable.CreateTexture2D(
            self.device,
            &desc,
            null,
            &tex,
        ))) return error.CreateTextureFailed;
        errdefer releaseAny(tex.?);

        const obj = self.interop.register(
            self.interop_device,
            tex.?,
            renderbuffer,
            GL_RENDERBUFFER,
            WGL_ACCESS_WRITE_DISCARD_NV,
        ) orelse return error.RegisterFailed;

        self.texture = tex;
        self.interop_object = obj;
        self.renderbuffer = renderbuffer;
    }

    pub fn releaseBackbuffer(self: *Presenter) void {
        if (self.interop_object) |obj| {
            _ = self.interop.unregister(self.interop_device, obj);
            self.interop_object = null;
        }
        if (self.texture) |tex| {
            releaseAny(tex);
            self.texture = null;
        }
    }

    pub fn lock(self: *Presenter) bool {
        const obj = self.interop_object orelse return false;
        return self.interop.lock(self.interop_device, 1, &[_]windows.HANDLE{obj}) != 0;
    }

    pub fn unlock(self: *Presenter) void {
        const obj = self.interop_object orelse return;
        _ = self.interop.unlock(self.interop_device, 1, &[_]windows.HANDLE{obj});
    }

    pub fn present(self: *Presenter, vsync: bool) void {
        // Copy the intermediate texture into the current backbuffer
        // (flip-model buffers rotate, so this is fetched per frame).
        const tex = self.texture orelse return;
        var buf: ?*anyopaque = null;
        if (!ok(self.swapchain.vtable.GetBuffer(
            self.swapchain,
            0,
            &IID_ID3D11Texture2D,
            &buf,
        ))) return;
        defer releaseAny(buf.?);
        self.context.vtable.CopyResource(self.context, buf.?, tex);

        const interval: u32 = if (vsync) 1 else 0;
        const hr = self.swapchain.vtable.Present(self.swapchain, interval, 0);
        if (!ok(hr)) log.warn("Present failed hr={x}", .{hr});
    }

    /// Resize the swapchain. The backbuffer must be re-acquired (and
    /// the caller's renderbuffer re-attached) afterwards.
    pub fn resize(self: *Presenter, width: u32, height: u32) !void {
        if (width == self.width and height == self.height) return;
        self.releaseBackbuffer();
        if (!ok(self.swapchain.vtable.ResizeBuffers(
            self.swapchain,
            2,
            @max(1, width),
            @max(1, height),
            DXGI_FORMAT_B8G8R8A8_UNORM,
            0,
        ))) return error.ResizeFailed;
        self.width = @max(1, width);
        self.height = @max(1, height);
    }
};
