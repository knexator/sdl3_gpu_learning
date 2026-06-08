const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const std_options: std.Options = .{ .log_level = .debug };

const target_triple: [:0]const u8 = x: {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    break :x (builtin.target.zigTriple(fba.allocator()) catch unreachable) ++ "";
};

const sdl_log = std.log.scoped(.sdl);
const app_log = std.log.scoped(.app);

const SpriteInstance = extern struct {
    x: f32,
    y: f32,
    z: f32,
    rotation: f32,
    w: f32,
    h: f32,
    padding_a: f32 = undefined,
    padding_b: f32 = undefined,
    tex_u: f32,
    tex_v: f32,
    tex_w: f32,
    tex_h: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const SPRITE_COUNT = 5;

const Matrix4x4 = [16]f32;

fn Matrix4x4_CreateOrthographicOffCenter(left: f32, right: f32, bottom: f32, top: f32, zNearPlane: f32, zFarPlane: f32) Matrix4x4 {
    return Matrix4x4{
        2.0 / (right - left),            0,                               0,                                     0,
        0,                               2.0 / (top - bottom),            0,                                     0,
        0,                               0,                               1.0 / (zNearPlane - zFarPlane),        0,
        (left + right) / (left - right), (top + bottom) / (bottom - top), zNearPlane / (zNearPlane - zFarPlane), 1,
    };
}

const camera_matrix = Matrix4x4_CreateOrthographicOffCenter(0, 640, 480, 0, 0, -1);

fn loadShader(
    comptime name: []const u8,
    sampler_count: u32,
    uniform_buffer_count: u32,
    storage_buffer_count: u32,
    storage_texture_count: u32,
) !*c.SDL_GPUShader {
    const stage = comptime if (std.mem.endsWith(u8, name, "vert"))
        c.SDL_GPU_SHADERSTAGE_VERTEX
    else if (std.mem.endsWith(u8, name, "frag"))
        c.SDL_GPU_SHADERSTAGE_FRAGMENT
    else
        unreachable;

    const code = @embedFile(name);
    const shader_info: c.SDL_GPUShaderCreateInfo = .{
        .code = code.ptr,
        .code_size = code.len,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = stage,
        .num_samplers = sampler_count,
        .num_uniform_buffers = uniform_buffer_count,
        .num_storage_buffers = storage_buffer_count,
        .num_storage_textures = storage_texture_count,
    };
    return errify(c.SDL_CreateGPUShader(device, &shader_info));
}

var fully_initialized = false;

var device: *c.SDL_GPUDevice = undefined;
var window: *c.SDL_Window = undefined;
var vertex_shader: *c.SDL_GPUShader = undefined;
var fragment_shader: *c.SDL_GPUShader = undefined;
var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var spritedata_buffer: *c.SDL_GPUBuffer = undefined;
var spritedata_transfer_buffer: *c.SDL_GPUTransferBuffer = undefined;
var index_buffer: *c.SDL_GPUBuffer = undefined;

fn sdlAppInit(appstate: ?*?*anyopaque, argv: [][*:0]u8) !c.SDL_AppResult {
    _ = appstate;
    _ = argv;

    std.log.debug("{s} {s}", .{ target_triple, @tagName(builtin.mode) });
    const platform: [*:0]const u8 = c.SDL_GetPlatform();
    sdl_log.debug("SDL platform: {s}", .{platform});
    sdl_log.debug("SDL build time version: {d}.{d}.{d}", .{
        c.SDL_MAJOR_VERSION,
        c.SDL_MINOR_VERSION,
        c.SDL_MICRO_VERSION,
    });
    sdl_log.debug("SDL build time revision: {s}", .{c.SDL_REVISION});
    {
        const version = c.SDL_GetVersion();
        sdl_log.debug("SDL runtime version: {d}.{d}.{d}", .{
            c.SDL_VERSIONNUM_MAJOR(version),
            c.SDL_VERSIONNUM_MINOR(version),
            c.SDL_VERSIONNUM_MICRO(version),
        });
        const revision: [*:0]const u8 = c.SDL_GetRevision();
        sdl_log.debug("SDL runtime revision: {s}", .{revision});
    }

    try errify(c.SDL_SetAppMetadata("gamename", "0.0.0", "example.zig-examples.gamename"));

    try errify(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMEPAD));
    // We don't need to call 'SDL_Quit()' when using main callbacks.

    sdl_log.debug("SDL video drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetCurrentVideoDriver().?,
        c.SDL_GetNumVideoDrivers(),
        c.SDL_GetVideoDriver,
    )});
    sdl_log.debug("SDL audio drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetCurrentAudioDriver().?,
        c.SDL_GetNumAudioDrivers(),
        c.SDL_GetAudioDriver,
    )});

    // errify(c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1")) catch {};

    device = try errify(c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV,
        builtin.mode == .Debug,
        null,
    ));
    errdefer c.SDL_DestroyGPUDevice(device);

    window = try errify(c.SDL_CreateWindow(
        "gamename",
        640,
        480,
        c.SDL_WINDOW_RESIZABLE,
    ));
    errdefer c.SDL_DestroyWindow(window);

    try errify(c.SDL_ClaimWindowForGPUDevice(device, window));
    errdefer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    vertex_shader = try loadShader(
        "PullSpriteBatch.vert",
        0,
        1,
        1,
        0,
    );
    errdefer c.SDL_ReleaseGPUShader(device, vertex_shader);
    fragment_shader = try loadShader(
        "UVColor.frag",
        0,
        0,
        0,
        0,
    );
    errdefer c.SDL_ReleaseGPUShader(device, fragment_shader);

    const pipeline_create_info: c.SDL_GPUGraphicsPipelineCreateInfo = .{
        .target_info = .{
            .num_color_targets = 1,
            .color_target_descriptions = &.{
                .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
                .blend_state = .{
                    .enable_blend = true,
                    .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                    .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                    .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                    .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                },
            },
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
    };

    pipeline = try errify(c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_create_info));
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    spritedata_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
        .size = @sizeOf(SpriteInstance) * SPRITE_COUNT,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, spritedata_buffer);

    // To get data into the vertex buffer, we have to use a transfer buffer
    spritedata_transfer_buffer = try errify(c.SDL_CreateGPUTransferBuffer(device, &.{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @sizeOf(SpriteInstance) * SPRITE_COUNT,
    }));
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, spritedata_transfer_buffer);

    index_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
        .size = @sizeOf(u16) * 6 * SPRITE_COUNT,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, index_buffer);

    {
        const index_transfer_buffer = try errify(c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @sizeOf(u16) * 6 * SPRITE_COUNT,
        }));
        defer c.SDL_ReleaseGPUTransferBuffer(device, index_transfer_buffer);

        const transfer_data_index: [*c]u16 = @ptrCast(@alignCast(try errify(c.SDL_MapGPUTransferBuffer(device, index_transfer_buffer, false))));
        const triangles_per_sprite = 2;
        const sprite_triangles: [triangles_per_sprite][3]usize = .{
            .{ 0, 1, 2 },
            .{ 3, 2, 1 },
        };
        const vertices_per_sprite = 4;
        for (0..SPRITE_COUNT) |sprite_index| {
            for (0..triangles_per_sprite, sprite_triangles) |triangle_index, triangle| {
                for (0..3) |k| {
                    transfer_data_index[
                        sprite_index * triangles_per_sprite * 3 + triangle_index * 3 + k
                    ] = @intCast(sprite_index * vertices_per_sprite + triangle[k]);
                }
            }
        }
        c.SDL_UnmapGPUTransferBuffer(device, index_transfer_buffer);

        const upload_cmd_buf = try errify(c.SDL_AcquireGPUCommandBuffer(device));
        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(upload_cmd_buf));

        c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = index_transfer_buffer,
            .offset = 0,
        }, &.{
            .buffer = index_buffer,
            .offset = 0,
            .size = @sizeOf(u16) * 6 * SPRITE_COUNT,
        }, false);

        c.SDL_EndGPUCopyPass(copy_pass);
        try errify(c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf));
    }

    fully_initialized = true;
    errdefer comptime unreachable;

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate(appstate: ?*anyopaque) !c.SDL_AppResult {
    _ = appstate;

    // Draw.
    {
        const cmdbuf = try errify(c.SDL_AcquireGPUCommandBuffer(device));
        var maybe_swapchain_texture: ?*c.SDL_GPUTexture = undefined;
        var w: u32, var h: u32 = .{ undefined, undefined };
        try errify(c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, window, &maybe_swapchain_texture, &w, &h));

        if (maybe_swapchain_texture) |swapchain_texture| {
            const data_ptr: [*c]SpriteInstance = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(
                device,
                spritedata_transfer_buffer,
                true,
            )));

            for (0..SPRITE_COUNT) |k| {
                data_ptr[k] = SpriteInstance{
                    .x = @floatFromInt(640 / 2 + k * 40),
                    .y = 480 / 2,
                    .z = 0,
                    .rotation = 0,
                    .w = 32,
                    .h = 32,
                    .tex_u = 0,
                    .tex_v = 0,
                    .tex_w = 1,
                    .tex_h = 1,
                    .r = 1,
                    .g = 1,
                    .b = 1,
                    .a = 1,
                };
            }
            c.SDL_UnmapGPUTransferBuffer(device, spritedata_transfer_buffer);

            const copy_pass = try errify(c.SDL_BeginGPUCopyPass(cmdbuf));
            c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = spritedata_transfer_buffer,
                .offset = 0,
            }, &c.SDL_GPUBufferRegion{
                .buffer = spritedata_buffer,
                .offset = 0,
                .size = SPRITE_COUNT * @sizeOf(SpriteInstance),
            }, true);
            c.SDL_EndGPUCopyPass(copy_pass);

            const color_target_info: c.SDL_GPUColorTargetInfo = .{
                .texture = swapchain_texture,
                .clear_color = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1.0 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            };

            const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);
            c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
            c.SDL_BindGPUVertexStorageBuffers(
                render_pass,
                0,
                &spritedata_buffer,
                1,
            );
            c.SDL_BindGPUIndexBuffer(render_pass, &c.SDL_GPUBufferBinding{
                .buffer = index_buffer,
                .offset = 0,
            }, c.SDL_GPU_INDEXELEMENTSIZE_16BIT);
            c.SDL_PushGPUVertexUniformData(cmdbuf, 0, &camera_matrix, @sizeOf(@TypeOf(camera_matrix)));
            // c.SDL_DrawGPUPrimitives(render_pass, SPRITE_COUNT * 6, 1, 0, 0);
            c.SDL_DrawGPUIndexedPrimitives(render_pass, SPRITE_COUNT * 6, 1, 0, 0, 0);

            c.SDL_EndGPURenderPass(render_pass);
        }

        try errify(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(appstate: ?*anyopaque, event: *c.SDL_Event) !c.SDL_AppResult {
    _ = appstate;

    switch (event.type) {
        c.SDL_EVENT_QUIT => {
            return c.SDL_APP_SUCCESS;
        },
        else => {},
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit(appstate: ?*anyopaque, result: anyerror!c.SDL_AppResult) void {
    _ = appstate;

    _ = result catch |err| if (err == error.SdlError) {
        sdl_log.err("{s}", .{c.SDL_GetError()});
    };

    if (fully_initialized) {
        c.SDL_ReleaseGPUBuffer(device, index_buffer);
        c.SDL_ReleaseGPUTransferBuffer(device, spritedata_transfer_buffer);
        c.SDL_ReleaseGPUBuffer(device, spritedata_buffer);
        c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        c.SDL_ReleaseGPUShader(device, fragment_shader);
        c.SDL_ReleaseGPUShader(device, vertex_shader);
        c.SDL_ReleaseWindowFromGPUDevice(device, window);
        c.SDL_DestroyWindow(window);
        c.SDL_DestroyGPUDevice(device);
        fully_initialized = false;
    }
}

fn fmtSdlDrivers(
    current_driver: [*:0]const u8,
    num_drivers: c_int,
    getDriver: *const fn (c_int) callconv(.c) ?[*:0]const u8,
) FormatSdlDrivers {
    return .{
        .current_driver = current_driver,
        .num_drivers = num_drivers,
        .getDriver = getDriver,
    };
}

const FormatSdlDrivers = struct {
    current_driver: [*:0]const u8,
    num_drivers: c_int,
    getDriver: *const fn (c_int) callconv(.c) ?[*:0]const u8,

    pub fn format(context: FormatSdlDrivers, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: c_int = 0;
        while (i < context.num_drivers) : (i += 1) {
            if (i != 0) {
                try writer.writeAll(", ");
            }
            const driver = context.getDriver(i).?;
            try writer.writeAll(std.mem.span(driver));
            if (std.mem.orderZ(u8, context.current_driver, driver) == .eq) {
                try writer.writeAll(" (current)");
            }
        }
    }
};

/// Converts the return value of an SDL function to an error union.
inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}

//#region SDL main callbacks boilerplate

pub fn main() !u8 {
    app_err.reset();
    var empty_argv: [0:null]?[*:0]u8 = .{};
    const status: u8 = @truncate(@as(c_uint, @bitCast(c.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));
    return app_err.load() orelse status;
}

fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    return c.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
}

fn sdlAppInitC(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
    return sdlAppInit(appstate.?, @ptrCast(argv.?[0..@intCast(argc)])) catch |err| app_err.store(err);
}

fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    return sdlAppIterate(appstate) catch |err| app_err.store(err);
}

fn sdlAppEventC(appstate: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    return sdlAppEvent(appstate, event.?) catch |err| app_err.store(err);
}

fn sdlAppQuitC(appstate: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    sdlAppQuit(appstate, app_err.load() orelse result);
}

var app_err: ErrorStore = .{};

const ErrorStore = struct {
    const status_not_stored = 0;
    const status_storing = 1;
    const status_stored = 2;

    status: c.SDL_AtomicInt = .{ .value = status_not_stored },
    err: anyerror = undefined,
    trace_index: usize = undefined,
    trace_addrs: [32]usize = undefined,

    fn reset(es: *ErrorStore) void {
        _ = c.SDL_SetAtomicInt(&es.status, status_not_stored);
    }

    fn store(es: *ErrorStore, err: anyerror) c.SDL_AppResult {
        if (c.SDL_CompareAndSwapAtomicInt(&es.status, status_not_stored, status_storing)) {
            es.err = err;
            if (@errorReturnTrace()) |src_trace| {
                es.trace_index = src_trace.index;
                const len = @min(es.trace_addrs.len, src_trace.instruction_addresses.len);
                @memcpy(es.trace_addrs[0..len], src_trace.instruction_addresses[0..len]);
            }
            _ = c.SDL_SetAtomicInt(&es.status, status_stored);
        }
        return c.SDL_APP_FAILURE;
    }

    fn load(es: *ErrorStore) ?anyerror {
        if (c.SDL_GetAtomicInt(&es.status) != status_stored) return null;
        if (@errorReturnTrace()) |dst_trace| {
            dst_trace.index = es.trace_index;
            const len = @min(dst_trace.instruction_addresses.len, es.trace_addrs.len);
            @memcpy(dst_trace.instruction_addresses[0..len], es.trace_addrs[0..len]);
        }
        return es.err;
    }
};

//#endregion SDL main callbacks boilerplate
