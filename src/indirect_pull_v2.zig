const std = @import("std");
const c = @import("c");

const main = @import("main.zig");
const loadShader = main.loadShader;
const errify = main.errify;

var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffer: Buffer(VertexData) = undefined;
var index_buffer: Buffer([3]u16) = undefined;
var draw_buffer: Buffer(c.SDL_GPUIndexedIndirectDrawCommand) = undefined;
var things_buffer: Buffer(ThingData) = undefined;

const VertexData = extern struct {
    pos: [3]f32,
    color: [4]u8,
};

const ThingData = extern struct {
    offset: [2]f32,
};

// transfer buffer size is always equal to the dynamic count
fn Buffer(T: type) type {
    return struct {
        const Self = @This();

        static_count: usize,
        dynamic_count: usize,
        mapped_ptr: ?[*]T,
        mapped_len: usize,

        this_frame_upload_count: usize = 0,

        sdl_buffer: *c.SDL_GPUBuffer,
        sdl_transfer_buffer: *c.SDL_GPUTransferBuffer,

        fn init(device: *c.SDL_GPUDevice, total_count: u32) !Self {
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

        fn deinit(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_ReleaseGPUTransferBuffer(device, self.sdl_transfer_buffer);
            c.SDL_ReleaseGPUBuffer(device, self.sdl_buffer);
        }

        fn freeze(self: *Self, device: *c.SDL_GPUDevice) void {
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

        fn startMap(self: *Self, device: *c.SDL_GPUDevice) !void {
            self.mapped_ptr = @ptrCast(@alignCast(try errify(
                c.SDL_MapGPUTransferBuffer(device, self.sdl_transfer_buffer, false),
            )));
            self.mapped_len = self.dynamic_count;
        }

        fn endMap(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_UnmapGPUTransferBuffer(device, self.sdl_transfer_buffer);
            self.mapped_ptr = null;
        }

        fn push(self: *Self, items: []const T) !void {
            if (self.mapped_ptr == null) @panic("can only push between .startMap and .endMap");
            if (items.len > self.mapped_len) return error.RanOutOfBuffer;
            @memcpy(self.mapped_ptr.?[0..items.len], items);
            self.mapped_ptr.? += items.len;
            self.mapped_len -= items.len;
        }

        fn upload(self: *Self, copy_pass: *c.SDL_GPUCopyPass) void {
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

pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
    if (true) { // build pipeline
        const vertex_shader = try loadShader(
            "IndirectPull.vert",
            0,
            0,
            2,
            0,
        );
        defer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const fragment_shader = try loadShader(
            "SolidColor.frag",
            0,
            0,
            0,
            0,
        );
        defer c.SDL_ReleaseGPUShader(device, fragment_shader);

        const pipeline_create_info: c.SDL_GPUGraphicsPipelineCreateInfo = .{
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &.{
                    .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
                },
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
        };

        pipeline = try errify(c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_create_info));
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    }

    vertex_buffer = try .init(device, 4);
    errdefer vertex_buffer.deinit(device);

    index_buffer = try .init(device, 6);
    errdefer index_buffer.deinit(device);

    draw_buffer = try .init(device, 2);
    errdefer draw_buffer.deinit(device);

    things_buffer = try .init(device, 3);
    errdefer things_buffer.deinit(device);

    if (true) { // vertex data
        try vertex_buffer.startMap(device);
        defer vertex_buffer.endMap(device);

        vertex_buffer.push(&.{
            .{ .pos = .{ -0.5, -0.5, 0 }, .color = .{ 255, 0, 0, 255 } },
            .{ .pos = .{ 0.5, -0.5, 0 }, .color = .{ 0, 255, 0, 255 } },
            .{ .pos = .{ 0.5, 0.5, 0 }, .color = .{ 0, 0, 255, 255 } },
            // .{ .pos = .{ -0.5, 0.5, 0 }, .color = .{ 255, 255, 255, 255 } },
        }) catch unreachable;
    }

    if (true) { // index data
        try index_buffer.startMap(device);
        defer index_buffer.endMap(device);

        index_buffer.push(&.{
            .{ 0, 1, 2 },
            .{ 0, 2, 3 },
        }) catch unreachable;
    }

    if (true) { // drawcalls data
        try draw_buffer.startMap(device);
        defer draw_buffer.endMap(device);

        draw_buffer.push(&.{ .{
            .num_indices = 6,
            .num_instances = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        }, .{
            .num_indices = 6,
            .num_instances = 2,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 1,
        } }) catch unreachable;
    }

    if (true) { // things data
        try things_buffer.startMap(device);
        defer things_buffer.endMap(device);

        things_buffer.push(&.{
            .{ .offset = .{ 0.25, 0.25 } },
            .{ .offset = .{ 0, -0.25 } },
            .{ .offset = .{ -0.8, 0 } },
        }) catch unreachable;
    }

    const upload_cmd_buf = try errify(c.SDL_AcquireGPUCommandBuffer(device));

    if (true) { // copy pass
        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(upload_cmd_buf));
        defer c.SDL_EndGPUCopyPass(copy_pass);

        vertex_buffer.upload(copy_pass);
        index_buffer.upload(copy_pass);
        draw_buffer.upload(copy_pass);
        things_buffer.upload(copy_pass);
    }

    try errify(c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf));

    vertex_buffer.freeze(device);
}

pub fn draw(device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
    if (true) { // update a vertex
        try vertex_buffer.startMap(device);
        try vertex_buffer.push(&.{
            .{ .pos = .{ -0.5, 0.5, 0 }, .color = .{ 255, 255, 255, 255 } },
        });
        vertex_buffer.endMap(device);
        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(cmdbuf));
        vertex_buffer.upload(copy_pass);
        c.SDL_EndGPUCopyPass(copy_pass);
    }

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
        &@as([2]*c.SDL_GPUBuffer, .{ vertex_buffer.sdl_buffer, things_buffer.sdl_buffer }),
        2,
    );
    c.SDL_BindGPUIndexBuffer(render_pass, &.{
        .buffer = index_buffer.sdl_buffer,
        .offset = 0,
    }, c.SDL_GPU_INDEXELEMENTSIZE_16BIT);
    c.SDL_DrawGPUIndexedPrimitivesIndirect(render_pass, draw_buffer.sdl_buffer, 0, 2);

    c.SDL_EndGPURenderPass(render_pass);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    things_buffer.deinit(device);
    draw_buffer.deinit(device);
    index_buffer.deinit(device);
    vertex_buffer.deinit(device);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}
