//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const global = @import("../global.zig");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const perf = @import("../perf.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// WGL completes frames synchronously and never exports them to an apprt.
/// EGL needs multiple frames while the apprt consumes previous exports.
pub const swap_chain_count = if (apprt.runtime == apprt.win32) 1 else 3;

const log = std.log.scoped(.opengl);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

vsync: bool,
flip_model: bool,
last_target: ?Target = null,
win32_surface: ?*apprt.Surface = null,
win32_dispatch: if (apprt.runtime == apprt.win32) ?gl.glad.Context else void = if (apprt.runtime == apprt.win32) null else {},

egl_display: if (apprt.runtime == apprt.win32) void else *gl.egl.Display,
egl_context: if (apprt.runtime == apprt.win32) void else *gl.egl.Context,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    if (comptime apprt.runtime == apprt.win32) return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .vsync = opts.config.vsync,
        .flip_model = opts.config.windows_flip_model,
        .egl_display = {},
        .egl_context = {},
    };
    try egl.load();

    const display: *egl.Display = try .initPlatform(
        egl.c.EGL_PLATFORM_SURFACELESS_MESA,
        egl.c.EGL_DEFAULT_DISPLAY,
        null,
    );

    log.info("EGL vendor={s}", .{display.queryString(.vendor) orelse "(unknown)"});
    log.info("EGL extensions={s}", .{display.queryString(.extensions) orelse "(unknown)"});

    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Choose a config. We need a config that is renderable with
    // OpenGL and a RGBA8 color buffer.
    const config = egl.Config.choose(display, &.{
        // EGL_SURFACE_TYPE defaults to EGL_WINDOW_BIT even though
        // we are rendering exclusively through surfaceless mode.
        // This is no problem on Mesa but we need to specify this
        // explicitly for proprietary Nvidia drivers.
        egl.c.EGL_SURFACE_TYPE,    0,
        egl.c.EGL_RENDERABLE_TYPE, egl.c.EGL_OPENGL_BIT,
        egl.c.EGL_RED_SIZE,        8,
        egl.c.EGL_GREEN_SIZE,      8,
        egl.c.EGL_BLUE_SIZE,       8,
        egl.c.EGL_ALPHA_SIZE,      8,
    }) catch |err| {
        log.warn("failed to choose config err={}", .{err});
        return err;
    };

    // Create our context.
    const context = egl.Context.create(display, config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .vsync = opts.config.vsync,
        .flip_model = false,
        .egl_display = display,
        .egl_context = context,
    };
}

pub fn deinit(self: *OpenGL) void {
    if (comptime apprt.runtime != apprt.win32) {
        self.egl_display.releaseCurrent();
        self.egl_context.destroy(self.egl_display) catch {};
    }

    // Do not destroy the EGL display here as
    // it is shared across the entire process.
    // It will get automatically torn down by the OS.
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    if (comptime apprt.runtime == apprt.win32) {
        try surface.glMakeCurrent();
        errdefer apprt.win32.Surface.glReleaseCurrent();
        try prepareContext(&apprt.win32.winapi.glGetProcAddress);
        self.win32_surface = surface;
        self.win32_dispatch = gl.glad.context;

        // Two presentation paths, selected by windows-flip-model:
        //
        // Classic (default): SwapBuffers into the window's
        // redirected surface. Camera-measured typing latency
        // favors this class of presentation (GDI conhost is the
        // fastest-measured Windows terminal; all flip/GPU
        // terminals measured ~2x slower) and our own PresentMon
        // numbers agree. Always vsync-throttled: sporadic typing
        // presents never block on the interval anyway, sustained
        // bursts throttle at the driver, and unthrottled
        // SwapBuffers once ran the GPU hot enough to trigger
        // driver timeouts (LiveKernelEvent 141).
        //
        // Flip-model (opt-in): DXGI swapchain on a DComp visual
        // (the Windows Terminal architecture), eligible for
        // hardware-overlay promotion, and the foundation for
        // future per-pixel transparency.
        if (self.flip_model and initPresenter(surface)) {
            log.info("flip-model presentation active", .{});
        } else {
            if (!apprt.win32.winapi.setSwapInterval(1)) {
                log.warn("wglSwapIntervalEXT unavailable; presentation unthrottled", .{});
            }
        }
        return;
    }
    try self.egl_display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    if (comptime apprt.runtime == apprt.win32) {
        if (currentWin32Surface()) |surface| deinitPresenter(surface);
        apprt.win32.Surface.glReleaseCurrent();
        gl.glad.unload();
        return;
    }
    self.egl_display.releaseCurrent();
    gl.glad.unload();
}

/// Select this surface on its shared Windows worker. Contexts stay assigned
/// to one worker; only the current context and thread-local dispatch change.
pub fn activateContext(self: *OpenGL) !void {
    if (comptime apprt.runtime != apprt.win32) return;
    const surface = self.win32_surface orelse return error.ContextNotInitialized;
    if (apprt.win32.winapi.wglGetCurrentDC() == surface.hdc) return;
    try surface.glMakeCurrent();
    gl.glad.context = self.win32_dispatch.?;
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;

    // On win32 we own the GL surface, so we are responsible for keeping
    // the viewport in sync with the window's client area (GTK's GLArea
    // does this implicitly). surfaceSize() reads the viewport back, so
    // this is also how drawFrame learns about resizes. The window is
    // recovered from the current DC to avoid plumbing a surface pointer
    // through the renderer.
    if (comptime apprt.runtime == apprt.win32) {
        const winapi = apprt.win32.winapi;
        const hdc = winapi.wglGetCurrentDC() orelse return;
        const hwnd = winapi.WindowFromDC(hdc) orelse return;
        var rect: winapi.RECT = undefined;
        if (winapi.GetClientRect(hwnd, &rect) == 0) return;
        gl.glad.context.Viewport.?(
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
        );

        // Flip-model: track window resizes with the swapchain.
        if (currentWin32Surface()) |surface| {
            if (surface.presenter) |*p| {
                const w: u32 = @intCast(@max(1, rect.right - rect.left));
                const h: u32 = @intCast(@max(1, rect.bottom - rect.top));
                if (w != p.width or h != p.height) resize: {
                    p.resize(w, h) catch |err| {
                        log.warn("swapchain resize failed err={}", .{err});
                        deinitPresenter(surface);
                        break :resize;
                    };
                    if (!attachBackbuffer(p)) {
                        deinitPresenter(surface);
                        break :resize;
                    }
                    // The frame being drawn may have been sampled at
                    // the old size (the resize message races this
                    // callback) and the resized GL framebuffer's
                    // content is undefined; queue a full follow-up
                    // render so a stale/blank frame can't be the last
                    // thing presented.
                    surface.core_surface.refreshCallback() catch {};
                }
            }
        }
    }
}

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *OpenGL) void {
    // We own the swap chain on win32: present the default framebuffer.
    // Hidden windows (background tabs) skip presentation entirely; with
    // vsync on, presenting an invisible window would also block this
    // renderer thread on the compositor for no benefit.
    if (comptime apprt.runtime == apprt.win32) {
        const winapi = apprt.win32.winapi;
        if (winapi.wglGetCurrentDC()) |hdc| {
            const hwnd = winapi.WindowFromDC(hdc);
            if (hwnd != null and winapi.IsWindowVisible(hwnd.?) == 0) return;

            present: {
                // Flip-model: copy the rendered frame (GL default
                // framebuffer, bottom-left origin) into the swapchain
                // backbuffer (top-left origin: flipped blit) and
                // present without queueing.
                if (currentWin32Surface()) |surface| {
                    if (surface.presenter) |*p| {
                        if (!p.lock()) {
                            log.warn("interop lock failed; dropping flip-model", .{});
                            deinitPresenter(surface);
                            break :present;
                        }

                        const ctx = gl.glad.context;
                        ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, 0);
                        ctx.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, p.fbo);
                        const w: i32 = @intCast(p.width);
                        const h: i32 = @intCast(p.height);
                        ctx.BlitFramebuffer.?(
                            0,
                            0,
                            w,
                            h,
                            0,
                            h,
                            w,
                            0,
                            gl.c.GL_COLOR_BUFFER_BIT,
                            gl.c.GL_NEAREST,
                        );
                        ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);

                        p.unlock();
                        if (!p.present(self.vsync)) {
                            // Device removed/reset (GPU TDR, driver
                            // update): the swapchain is dead. Rebuild
                            // the presenter on a fresh device; if that
                            // fails, fall back to SwapBuffers rather
                            // than freezing on a dead swapchain.
                            log.warn("device lost; rebuilding presenter", .{});
                            deinitPresenter(surface);
                            if (!initPresenter(surface)) {
                                log.warn(
                                    "presenter rebuild failed; using SwapBuffers",
                                    .{},
                                );
                            }
                            // The new backbuffer holds no frame yet.
                            surface.core_surface.refreshCallback() catch {};
                            break :present;
                        }

                        if (perf.keyToPresent()) |ns| {
                            log.info("perf: key-to-present {d} us", .{ns / 1000});
                        }
                        return;
                    }
                }
            }

            // Legacy path.
            if (winapi.SwapBuffers(hdc) == 0) {
                log.warn("SwapBuffers failed", .{});
            }

            // Key-to-present latency tracing (GHOSTTY_PERF_TRACE).
            // This is the full echo path: key encode, pty write,
            // shell echo, ConPTY, parse, damage, render, present.
            if (perf.keyToPresent()) |ns| {
                log.info("perf: key-to-present {d} us", .{ns / 1000});
            }
            if (perf.sinceKeyMs()) |ms| {
                log.info("perf: present key+{d}ms", .{ms});
            }
        }
    }
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(self: *OpenGL, target: Target) !ExportedFrame {
    if (comptime apprt.runtime == apprt.win32) return self.presentWin32(target);
    if (target.exportDmabuf(self.egl_display, self.egl_context)) |dmabuf| {
        return .{ .dmabuf = dmabuf };
    } else |_| {
        // If DMABUFs fail, then use CPU buffers
        return .{ .memory = .{
            .width = @intCast(target.width),
            .height = @intCast(target.height),
            .pixels = try target.readPixelsAlloc(self.alloc),
            .alloc = self.alloc,
        } };
    }
}

/// A finished frame exported for presentation by the apprt.
pub const ExportedFrame = if (apprt.runtime == apprt.win32) void else union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2d",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

fn currentWin32Surface() ?*apprt.win32.Surface {
    const winapi = apprt.win32.winapi;
    const hdc = winapi.wglGetCurrentDC() orelse return null;
    const hwnd = winapi.WindowFromDC(hdc) orelse return null;
    const ptr = winapi.GetWindowLongPtrW(hwnd, winapi.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn initPresenter(surface: *apprt.Surface) bool {
    if (comptime apprt.runtime != apprt.win32) return false;
    const winapi = apprt.win32.winapi;

    // Escape hatch for benchmarking and driver-issue workarounds.
    if (global.environ().getWindows(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_NO_FLIP")) != null) return false;

    var client: winapi.RECT = undefined;
    if (winapi.GetClientRect(surface.host, &client) == 0) return false;

    var presenter = apprt.win32.Surface.dxgi.Presenter.init(
        surface.host,
        @intCast(@max(1, client.right - client.left)),
        @intCast(@max(1, client.bottom - client.top)),
    ) catch |err| {
        // With windows-flip-model on, the host window was created with
        // WS_EX_NOREDIRECTIONBITMAP (creation-only): SwapBuffers has no
        // redirection surface to present into, so this fallback shows a
        // blank window. The startup probe exercises the full presenter
        // pipeline to make this unreachable in practice; if it fires
        // anyway, say so loudly rather than failing silently.
        log.err(
            "flip-model presenter failed at runtime err={}; the SwapBuffers " ++
                "fallback cannot display into a WS_EX_NOREDIRECTIONBITMAP host — " ++
                "if this window is blank, unset windows-flip-model",
            .{err},
        );
        return false;
    };

    if (!attachBackbuffer(&presenter)) {
        presenter.deinit();
        return false;
    }

    surface.presenter = presenter;
    return true;
}

fn deinitPresenter(surface: *apprt.win32.Surface) void {
    if (surface.presenter) |*p| {
        const ctx = gl.glad.context;
        if (p.fbo != 0) ctx.DeleteFramebuffers.?(1, &p.fbo);
        if (p.renderbuffer != 0) ctx.DeleteRenderbuffers.?(1, &p.renderbuffer);
        p.deinit();
        surface.presenter = null;
    }
}

fn attachBackbuffer(p: *apprt.win32.Surface.dxgi.Presenter) bool {
    const ctx = gl.glad.context;

    if (p.renderbuffer == 0) ctx.GenRenderbuffers.?(1, &p.renderbuffer);
    if (p.fbo == 0) ctx.GenFramebuffers.?(1, &p.fbo);

    p.acquireBackbuffer(p.renderbuffer) catch |err| {
        log.warn("backbuffer interop failed err={}", .{err});
        return false;
    };

    ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, p.fbo);
    ctx.FramebufferRenderbuffer.?(
        gl.c.GL_FRAMEBUFFER,
        gl.c.GL_COLOR_ATTACHMENT0,
        gl.c.GL_RENDERBUFFER,
        p.renderbuffer,
    );
    ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);
    return true;
}

pub fn presentLastTarget(self: *OpenGL) !void {
    if (comptime apprt.runtime == apprt.win32) {
        if (self.last_target) |target| try self.presentWin32(target);
    }
}

pub fn gpuResourcesReleased(self: *OpenGL, shader_set: *const shaders.Shaders) void {
    self.last_target = null;
    shader_set.releaseFrameResources();
    // A hidden surface may not submit another frame for a long time.
    // Submit pending deletions without waiting for the GPU to finish.
    gl.flush();
}

fn presentWin32(self: *OpenGL, target: Target) !void {
    // In order to present a target we blit it to the default framebuffer.

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    // Bind the target for reading.
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();

    // Blit
    gl.glad.context.BlitFramebuffer.?(
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        gl.c.GL_COLOR_BUFFER_BIT,
        gl.c.GL_NEAREST,
    );

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;
}
