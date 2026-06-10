const std = @import("std");
const c = @import("c");
const main = @import("main.zig");
const errify = main.errify;

// transfer buffer size is always equal to the dynamic count
pub fn Buffer(T: type) type {
    return struct {
        const Self = @This();

        static_count: usize,
        dynamic_count: usize,
        mapped_ptr: ?[*]T,
        mapped_len: usize,

        this_frame_upload_count: usize = 0,

        sdl_buffer: *c.SDL_GPUBuffer,
        sdl_transfer_buffer: *c.SDL_GPUTransferBuffer,

        pub fn init(device: *c.SDL_GPUDevice, total_count: u32) !Self {
            const total_size: u32 = @sizeOf(T) * total_count;

            const sdl_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
                .usage = if (T == c.SDL_GPUIndexedIndirectDrawCommand)
                    c.SDL_GPU_BUFFERUSAGE_INDIRECT
                else if (T == [3]u16 or T == [3]u32)
                    c.SDL_GPU_BUFFERUSAGE_INDEX
                else
                    c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
                .size = total_size,
            }));
            errdefer c.SDL_ReleaseGPUBuffer(device, sdl_buffer);

            const sdl_transfer_buffer: *c.SDL_GPUTransferBuffer = try errify(c.SDL_CreateGPUTransferBuffer(
                device,
                &.{
                    .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                    .size = total_size,
                },
            ));
            errdefer c.SDL_ReleaseGPUTransferBuffer(device, sdl_transfer_buffer);

            return .{
                .static_count = 0,
                .dynamic_count = total_count,
                .mapped_ptr = null,
                .mapped_len = 0,
                .sdl_buffer = sdl_buffer,
                .sdl_transfer_buffer = sdl_transfer_buffer,
            };
        }

        pub fn deinit(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_ReleaseGPUTransferBuffer(device, self.sdl_transfer_buffer);
            c.SDL_ReleaseGPUBuffer(device, self.sdl_buffer);
        }

        pub fn freeze(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_ReleaseGPUTransferBuffer(device, self.sdl_transfer_buffer);
            const queued_dynamic = self.dynamic_count - self.mapped_len;
            self.static_count += queued_dynamic;
            self.dynamic_count -= queued_dynamic;
            self.sdl_transfer_buffer = errify(c.SDL_CreateGPUTransferBuffer(
                device,
                &.{
                    .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                    .size = @intCast(@sizeOf(T) * self.dynamic_count),
                },
            )) catch std.debug.panic("failed to freeze buffer; panicking to avoid leaving it in an inconsistent state", .{});
        }

        pub fn startMap(self: *Self, device: *c.SDL_GPUDevice) !void {
            self.mapped_ptr = @ptrCast(@alignCast(try errify(
                c.SDL_MapGPUTransferBuffer(device, self.sdl_transfer_buffer, false),
            )));
            self.mapped_len = self.dynamic_count;
        }

        pub fn endMap(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_UnmapGPUTransferBuffer(device, self.sdl_transfer_buffer);
            self.mapped_ptr = null;
        }

        pub fn push(self: *Self, items: []const T) !void {
            if (self.mapped_ptr == null) @panic("can only push between .startMap and .endMap");
            if (items.len > self.mapped_len) return error.RanOutOfBuffer;
            @memcpy(self.mapped_ptr.?[0..items.len], items);
            self.mapped_ptr.? += items.len;
            self.mapped_len -= items.len;
        }

        pub fn upload(self: *Self, copy_pass: *c.SDL_GPUCopyPass) void {
            if (self.mapped_ptr != null) @panic("can't upload between .startMap and .endMap");
            c.SDL_UploadToGPUBuffer(copy_pass, &.{
                .transfer_buffer = self.sdl_transfer_buffer,
                .offset = 0,
            }, &.{
                .buffer = self.sdl_buffer,
                .offset = @intCast(@sizeOf(T) * self.static_count),
                .size = @intCast(@sizeOf(T) * (self.dynamic_count - self.mapped_len)),
            }, false);
        }
    };
}
