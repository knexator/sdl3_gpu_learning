const std = @import("std");
const c = @import("c");

const main = @import("main.zig");
const loadShader = main.loadShader;
const errify = main.errify;

fn Buffer(T: type) type {
    return struct {
        const Self = @This();

        total_count: usize,
        mapped_ptr: ?[*]T,
        pushed_count: usize,

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
                    c.SDL_GPU_BUFFERUSAGE_VERTEX,
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
                .total_count = total_count,
                .mapped_ptr = null,
                .pushed_count = 0,
                .sdl_buffer = sdl_buffer,
                .sdl_transfer_buffer = sdl_transfer_buffer,
            };
        }

        pub fn deinit(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_ReleaseGPUTransferBuffer(device, self.sdl_transfer_buffer);
            c.SDL_ReleaseGPUBuffer(device, self.sdl_buffer);
        }

        pub fn startMap(self: *Self, device: *c.SDL_GPUDevice) !void {
            const tb = self.sdl_transfer_buffer;
            self.mapped_ptr = @ptrCast(@alignCast(try errify(
                c.SDL_MapGPUTransferBuffer(device, tb, true),
            )));
            self.pushed_count = 0;
        }

        pub fn endMap(self: *Self, device: *c.SDL_GPUDevice) void {
            c.SDL_UnmapGPUTransferBuffer(device, self.sdl_transfer_buffer);
            self.mapped_ptr = null;
        }

        pub fn push(self: *Self, items: []const T) !void {
            if (self.mapped_ptr == null) @panic("can only push between .startMap and .endMap");
            if (items.len > (self.total_count - self.pushed_count)) return error.RanOutOfBuffer;
            @memcpy(self.mapped_ptr.?[0..items.len], items);
            self.mapped_ptr.? += items.len;
            self.pushed_count += items.len;
        }

        pub fn upload(self: *Self, copy_pass: *c.SDL_GPUCopyPass) void {
            if (self.mapped_ptr != null) @panic("can't upload between .startMap and .endMap");
            c.SDL_UploadToGPUBuffer(copy_pass, &.{
                .transfer_buffer = self.sdl_transfer_buffer,
                .offset = 0,
            }, &.{
                .buffer = self.sdl_buffer,
                .offset = 0,
                .size = @intCast(@sizeOf(T) * self.pushed_count),
            }, true);
        }
    };
}

var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffer: Buffer(VertexData) = undefined;
var index_buffer: Buffer([3]u16) = undefined;

const vertex_count = std.math.maxInt(u16);
const index_count = std.math.maxInt(u16);

const texture_count = 0;

const VertexData = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

const Model = struct {
    vertices: []const VertexData,
    indices: []const [3]u16,
};

const tri: Model = .{
    .indices = &.{.{ 0, 1, 2 }},
    .vertices = &.{
        .{ .pos = .{ -0.25, -0.22 }, .uv = .{ -0.25, -0.22 }, .color = .{ 255, 255, 255, 255 } },
        .{ .pos = .{ 0.25, -0.22 }, .uv = .{ 0.25, -0.22 }, .color = .{ 255, 255, 255, 255 } },
        .{ .pos = .{ 0.0, 0.28 }, .uv = .{ 0.0, 0.28 }, .color = .{ 255, 255, 255, 255 } },
    },
};
const quad: Model = .{
    .indices = &.{
        .{ 0, 1, 2 },
        .{ 0, 2, 3 },
    },
    .vertices = &.{
        .{ .pos = .{ -0.3, -0.3 }, .uv = .{ 0, 1 }, .color = .{ 255, 0, 0, 255 } },
        .{ .pos = .{ 0.3, -0.3 }, .uv = .{ 1, 1 }, .color = .{ 0, 255, 0, 255 } },
        .{ .pos = .{ 0.3, 0.3 }, .uv = .{ 1, 0 }, .color = .{ 0, 0, 255, 255 } },
        .{ .pos = .{ -0.3, 0.3 }, .uv = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 } },
    },
};

pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
    if (true) { // build pipeline
        const vertex_shader = try loadShader("CpuBatcher.vert", 0, 0, 0, 0);
        defer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const fragment_shader = try loadShader("CpuBatcher.frag", texture_count, 0, 0, 0);
        defer c.SDL_ReleaseGPUShader(device, fragment_shader);

        const pipeline_create_info: c.SDL_GPUGraphicsPipelineCreateInfo = .{
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &.{
                    .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
                },
            },
            // This is set up to match the vertex shader layout!
            .vertex_input_state = .{
                .num_vertex_buffers = 1,
                .vertex_buffer_descriptions = &c.SDL_GPUVertexBufferDescription{
                    .slot = 0,
                    .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                    .instance_step_rate = 0,
                    .pitch = @sizeOf(VertexData),
                },
                .num_vertex_attributes = 3,
                .vertex_attributes = &[3]c.SDL_GPUVertexAttribute{ .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                    .location = 0,
                    .offset = @offsetOf(VertexData, "pos"),
                }, .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                    .location = 1,
                    .offset = @offsetOf(VertexData, "uv"),
                }, .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM,
                    .location = 2,
                    .offset = @offsetOf(VertexData, "color"),
                } },
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
        };

        pipeline = try errify(c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_create_info));
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    }

    vertex_buffer = try .init(device, vertex_count);
    errdefer vertex_buffer.deinit(device);

    index_buffer = try .init(device, index_count);
    errdefer index_buffer.deinit(device);
}

pub fn draw(device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
    if (true) { // push all the stuff
        try vertex_buffer.startMap(device);
        defer vertex_buffer.endMap(device);
        try index_buffer.startMap(device);
        defer index_buffer.endMap(device);

        try vertex_buffer.push(quad.vertices);
        try index_buffer.push(quad.indices);

        const time: f32 = @as(f32, @floatFromInt(c.SDL_GetTicks())) / 1000.0;
        try vertex_buffer.push(&.{
            .{ .pos = .{ 0.5, -0.3 }, .uv = .{ 0, 1 }, .color = .{ 255, 0, 0, 255 } },
            .{ .pos = .{ 0.7, -0.3 }, .uv = .{ 1, 1 }, .color = .{ 0, 255, 0, 255 } },
            .{ .pos = .{ 0.7, 0.3 + 0.1 * @cos(time) }, .uv = .{ 1, 0 }, .color = .{ 0, 0, 255, 255 } },
            .{ .pos = .{ 0.5, 0.3 + 0.1 * @sin(time) }, .uv = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 } },
        });
        try index_buffer.push(&.{
            .{ 4, 5, 6 },
            .{ 4, 6, 7 },
        });
    }

    if (true) { // copy pass
        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(cmdbuf));
        defer c.SDL_EndGPUCopyPass(copy_pass);

        vertex_buffer.upload(copy_pass);
        index_buffer.upload(copy_pass);
    }

    const color_target_info: c.SDL_GPUColorTargetInfo = .{
        .texture = swapchain_texture,
        .clear_color = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1.0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);

    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
    c.SDL_BindGPUVertexBuffers(render_pass, 0, &.{
        .buffer = vertex_buffer.sdl_buffer,
        .offset = 0,
    }, 1);
    c.SDL_BindGPUIndexBuffer(render_pass, &.{
        .buffer = index_buffer.sdl_buffer,
        .offset = 0,
    }, c.SDL_GPU_INDEXELEMENTSIZE_16BIT);
    c.SDL_DrawGPUIndexedPrimitives(render_pass, @intCast(index_buffer.pushed_count * 3), 1, 0, 0, 0);

    c.SDL_EndGPURenderPass(render_pass);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    index_buffer.deinit(device);
    vertex_buffer.deinit(device);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}
