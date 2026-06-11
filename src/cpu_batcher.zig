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

const texture_count = 3;

var textures: [texture_count]*c.SDL_GPUTexture = undefined;
var sampler: *c.SDL_GPUSampler = undefined;

const VertexData = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
    texture_id: u32,
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
                .num_vertex_attributes = 4,
                .vertex_attributes = &[4]c.SDL_GPUVertexAttribute{ .{
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
                }, .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UINT,
                    .location = 3,
                    .offset = @offsetOf(VertexData, "texture_id"),
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

    sampler = try errify(c.SDL_CreateGPUSampler(device, &.{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    }));
    errdefer c.SDL_ReleaseGPUSampler(device, sampler);

    // The fixed texture set. material 0 = an image; materials 1,2 = procedural.
    const proc_dim = 64;
    var checker: [proc_dim * proc_dim * 4]u8 = undefined;
    var gradient: [proc_dim * proc_dim * 4]u8 = undefined;
    for (0..proc_dim) |y| {
        for (0..proc_dim) |x| {
            const i = (y * proc_dim + x) * 4;
            const on = ((x / 8) + (y / 8)) % 2 == 0;
            checker[i + 0] = if (on) 230 else 30;
            checker[i + 1] = if (on) 80 else 30;
            checker[i + 2] = if (on) 30 else 30;
            checker[i + 3] = 255;
            gradient[i + 0] = @intCast(x * 255 / (proc_dim - 1));
            gradient[i + 1] = @intCast(y * 255 / (proc_dim - 1));
            gradient[i + 2] = 200;
            gradient[i + 3] = 255;
        }
    }

    const image_bmp = @embedFile("ravioli.bmp");
    const image_bmp_io = try errify(c.SDL_IOFromConstMem(image_bmp, image_bmp.len));
    const image_data = try errify(c.SDL_LoadBMP_IO(image_bmp_io, true));
    defer c.SDL_DestroySurface(image_data);
    const image_w: u32 = @intCast(image_data.*.w);
    const image_h: u32 = @intCast(image_data.*.h);

    // Create the three textures and a transfer buffer per texture.
    const Tex = struct { w: u32, h: u32, pixels: [*]const u8 };
    const tex_specs = [texture_count]Tex{
        .{ .w = image_w, .h = image_h, .pixels = @ptrCast(image_data.*.pixels) },
        .{ .w = proc_dim, .h = proc_dim, .pixels = &checker },
        .{ .w = proc_dim, .h = proc_dim, .pixels = &gradient },
    };
    var tex_transfers: [texture_count]*c.SDL_GPUTransferBuffer = undefined;
    for (tex_specs, 0..) |spec, i| {
        textures[i] = try errify(c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .width = spec.w,
            .height = spec.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        }));
        errdefer c.SDL_ReleaseGPUTexture(device, textures[i]);

        tex_transfers[i] = try errify(c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = spec.w * spec.h * 4,
        }));

        const ptr: [*]u8 = @ptrCast(@alignCast(try errify(
            c.SDL_MapGPUTransferBuffer(device, tex_transfers[i], false),
        )));
        @memcpy(ptr[0 .. spec.w * spec.h * 4], spec.pixels[0 .. spec.w * spec.h * 4]);
        c.SDL_UnmapGPUTransferBuffer(device, tex_transfers[i]);
    }
    defer for (tex_transfers) |tb| c.SDL_ReleaseGPUTransferBuffer(device, tb);

    const upload_cmd_buf = try errify(c.SDL_AcquireGPUCommandBuffer(device));

    if (true) { // copy pass: upload the static buffers and all textures once
        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(upload_cmd_buf));
        defer c.SDL_EndGPUCopyPass(copy_pass);

        for (tex_specs, 0..) |spec, i| {
            c.SDL_UploadToGPUTexture(copy_pass, &.{
                .transfer_buffer = tex_transfers[i],
                .offset = 0,
            }, &.{
                .texture = textures[i],
                .w = spec.w,
                .h = spec.h,
                .d = 1,
            }, false);
        }
    }

    try errify(c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf));
}

pub fn draw(device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
    if (true) { // push all the stuff
        try vertex_buffer.startMap(device);
        defer vertex_buffer.endMap(device);
        try index_buffer.startMap(device);
        defer index_buffer.endMap(device);

        try vertex_buffer.push(&.{
            .{ .pos = .{ -0.3, -0.3 }, .uv = .{ 0, 1 }, .color = .{ 255, 0, 0, 255 }, .texture_id = 0 },
            .{ .pos = .{ 0.3, -0.3 }, .uv = .{ 1, 1 }, .color = .{ 0, 255, 0, 255 }, .texture_id = 0 },
            .{ .pos = .{ 0.3, 0.3 }, .uv = .{ 1, 0 }, .color = .{ 0, 0, 255, 255 }, .texture_id = 0 },
            .{ .pos = .{ -0.3, 0.3 }, .uv = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 }, .texture_id = 0 },
        });
        try index_buffer.push(&.{
            .{ 0, 1, 2 },
            .{ 0, 2, 3 },
        });

        const time: f32 = @as(f32, @floatFromInt(c.SDL_GetTicks())) / 1000.0;
        try vertex_buffer.push(&.{
            .{ .pos = .{ 0.5, -0.3 }, .uv = .{ 0, 1 }, .color = .{ 255, 0, 0, 255 }, .texture_id = 2 },
            .{ .pos = .{ 0.7, -0.3 }, .uv = .{ 1, 1 }, .color = .{ 0, 255, 0, 255 }, .texture_id = 2 },
            .{ .pos = .{ 0.7, 0.3 + 0.1 * @cos(time) }, .uv = .{ 1, 0 }, .color = .{ 0, 0, 255, 255 }, .texture_id = 2 },
            .{ .pos = .{ 0.5, 0.3 + 0.1 * @sin(time) }, .uv = .{ 0, 0 }, .color = .{ 255, 255, 255, 255 }, .texture_id = 2 },
        });
        try index_buffer.push(&.{
            .{ 4, 5, 6 },
            .{ 4, 6, 7 },
        });

        try vertex_buffer.push(&.{
            .{ .pos = .{ -0.5, -0.3 }, .uv = .{ 0, 1 }, .color = .{ 255, 0, 0, 255 }, .texture_id = 1 },
            .{ .pos = .{ -0.7, -0.3 }, .uv = .{ 1, 1 }, .color = .{ 0, 255, 0, 255 }, .texture_id = 1 },
            .{ .pos = .{ -0.6, 0.3 }, .uv = .{ 0.5, 0 }, .color = .{ 0, 0, 255, 255 }, .texture_id = 1 },
        });
        try index_buffer.push(&.{
            .{ 8, 9, 10 },
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

    var sampler_bindings: [texture_count]c.SDL_GPUTextureSamplerBinding = undefined;
    for (&sampler_bindings, textures) |*binding, tex| {
        binding.* = .{ .texture = tex, .sampler = sampler };
    }

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
    c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_bindings, texture_count);
    c.SDL_DrawGPUIndexedPrimitives(render_pass, @intCast(index_buffer.pushed_count * 3), 1, 0, 0, 0);

    c.SDL_EndGPURenderPass(render_pass);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    for (textures) |tex| c.SDL_ReleaseGPUTexture(device, tex);
    c.SDL_ReleaseGPUSampler(device, sampler);
    index_buffer.deinit(device);
    vertex_buffer.deinit(device);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}
