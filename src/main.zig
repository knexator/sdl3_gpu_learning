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

var fully_initialized = false;

const window_w = 640;
const window_h = 480;
var window: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;

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

    try errify(c.SDL_SetAppMetadata("Speedbreaker", "0.0.0", "example.zig-examples.breakout"));

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

    errify(c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "1")) catch {};

    try errify(c.SDL_CreateWindowAndRenderer("Speedbreaker", window_w, window_h, 0, @ptrCast(&window), @ptrCast(&renderer)));
    errdefer c.SDL_DestroyWindow(window);
    errdefer c.SDL_DestroyRenderer(renderer);

    sdl_log.debug("SDL render drivers: {f}", .{fmtSdlDrivers(
        c.SDL_GetRendererName(renderer).?,
        c.SDL_GetNumRenderDrivers(),
        c.SDL_GetRenderDriver,
    )});

    fully_initialized = true;
    errdefer comptime unreachable;

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate(appstate: ?*anyopaque) !c.SDL_AppResult {
    _ = appstate;

    // Draw.
    {
        try errify(c.SDL_SetRenderDrawColor(renderer, 0x47, 0x5b, 0x8d, 0xff));

        try errify(c.SDL_RenderClear(renderer));

        try errify(c.SDL_RenderPresent(renderer));
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
        c.SDL_DestroyRenderer(renderer);
        c.SDL_DestroyWindow(window);
        fully_initialized = false;
    }
}

/// Facilitates updating the game logic at a fixed rate.
/// Inspired <https://github.com/TylerGlaiel/FrameTimingControl> and the linked article.
const Timekeeper = struct {
    const updates_per_s = 60;
    const max_accumulated_updates = 8;
    const snap_frame_rates = .{ updates_per_s, 30, 120, 144 };
    const ticks_per_tock = 720; // Least common multiple of 'snap_frame_rates'
    const snap_tolerance_us = 200;
    const us_per_s = 1_000_000;

    tocks_per_s: u64,
    accumulated_ticks: u64 = 0,
    previous_timestamp: ?u64 = null,

    fn consume(timekeeper_: *Timekeeper) bool {
        const ticks_per_s: u64 = timekeeper_.tocks_per_s * ticks_per_tock;
        const ticks_per_update: u64 = @divExact(ticks_per_s, updates_per_s);
        if (timekeeper_.accumulated_ticks >= ticks_per_update) {
            timekeeper_.accumulated_ticks -= ticks_per_update;
            return true;
        } else {
            return false;
        }
    }

    fn produce(timekeeper_: *Timekeeper, current_timestamp: u64) void {
        if (timekeeper_.previous_timestamp) |previous_timestamp| {
            const ticks_per_s: u64 = timekeeper_.tocks_per_s * ticks_per_tock;
            const elapsed_ticks: u64 = (current_timestamp -% previous_timestamp) *| ticks_per_tock;
            const snapped_elapsed_ticks: u64 = inline for (snap_frame_rates) |snap_frame_rate| {
                const target_ticks: u64 = @divExact(ticks_per_s, snap_frame_rate);
                const abs_diff = @max(elapsed_ticks, target_ticks) - @min(elapsed_ticks, target_ticks);
                if (abs_diff *| us_per_s <= snap_tolerance_us *| ticks_per_s) {
                    break target_ticks;
                }
            } else elapsed_ticks;
            const ticks_per_update: u64 = @divExact(ticks_per_s, updates_per_s);
            const max_accumulated_ticks: u64 = max_accumulated_updates * ticks_per_update;
            timekeeper_.accumulated_ticks = @min(timekeeper_.accumulated_ticks +| snapped_elapsed_ticks, max_accumulated_ticks);
        }
        timekeeper_.previous_timestamp = current_timestamp;
    }
};

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
