const std = @import("std");
const c = @import("c");
const assert = std.debug.assert;

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

        pub fn init(device: *c.SDL_GPUDevice, total_count: u32, usage: enum { vertex, index, indirect, storage }) !Self {
            const total_size: u32 = @sizeOf(T) * total_count;

            const sdl_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
                .usage = switch (usage) {
                    .indirect => c.SDL_GPU_BUFFERUSAGE_INDIRECT,
                    .index => c.SDL_GPU_BUFFERUSAGE_INDEX,
                    .vertex => c.SDL_GPU_BUFFERUSAGE_VERTEX,
                    .storage => c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
                },
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

const Vertex = extern struct {
    relative_pos: [2]f32,
    uv: [2]f32,
};

const Drawable = extern struct {
    camera_center: [2]f32,
    camera_axis_x: [2]f32,
    camera_axis_y: [2]f32,
    _pad0: [2]u32 = undefined,
    color: [4]f32,
    texture_id: u32,
    material_id: u32,
    _pad1: [8]u8 = undefined,
};

comptime {
    assert(hasNoImplicitPadding(Vertex));
    assert(hasNoImplicitPadding(Drawable));
    validateHlslStructuredBuffer(Drawable);
}

pub const Renderer = struct {
    pipeline: *c.SDL_GPUGraphicsPipeline,
    vertex_buffer: Buffer(Vertex),
    index_buffer: Buffer([3]u16),
    drawable_buffer: Buffer(Drawable),
    drawcall_buffer: Buffer(c.SDL_GPUIndexedIndirectDrawCommand),

    textures: [texture_count]?*c.SDL_GPUTexture,
    samplers: [texture_count]?*c.SDL_GPUSampler,
    const texture_count = 2;

    const max_vertex_count = std.math.maxInt(u16);
    const max_drawables_count = std.math.maxInt(u16);
    comptime { // make sure i didn't confuse the power of two
        assert(65_000 < max_vertex_count and max_vertex_count < 66_000);
    }

    pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !Renderer {
        var result: Renderer = undefined;

        result.textures = @splat(null);
        result.samplers = @splat(null);

        result.pipeline = blk: {
            const vertex_shader = try loadShader(
                "RendererUber.vert",
                0,
                0,
                1,
                0,
            );
            defer c.SDL_ReleaseGPUShader(device, vertex_shader);

            const fragment_shader = try loadShader(
                "RendererUber.frag",
                texture_count,
                0,
                0,
                0,
            );
            defer c.SDL_ReleaseGPUShader(device, fragment_shader);

            const vertex_attributes: [@typeInfo(Vertex).@"struct".fields.len]c.SDL_GPUVertexAttribute = .{
                .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "relative_pos") },
                .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
            };
            const vertex_buffer_descriptions: [1]c.SDL_GPUVertexBufferDescription = .{
                .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
            };

            const pipeline_create_info: c.SDL_GPUGraphicsPipelineCreateInfo = .{
                .target_info = .{
                    .num_color_targets = 1,
                    .color_target_descriptions = &.{
                        .format = c.SDL_GetGPUSwapchainTextureFormat(device, window),
                        .blend_state = .{
                            .enable_blend = true,
                            // TODO: revise
                            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
                            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                        },
                    },
                },
                .vertex_input_state = .{
                    .num_vertex_buffers = vertex_buffer_descriptions.len,
                    .vertex_buffer_descriptions = &vertex_buffer_descriptions,
                    .num_vertex_attributes = vertex_attributes.len,
                    .vertex_attributes = &vertex_attributes,
                },
                .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
                .vertex_shader = vertex_shader,
                .fragment_shader = fragment_shader,
            };

            break :blk try errify(c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_create_info));
        };
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, result.pipeline);

        result.vertex_buffer = try .init(device, max_vertex_count, .vertex);
        errdefer result.vertex_buffer.deinit(device);

        result.index_buffer = try .init(device, max_vertex_count, .index);
        errdefer result.index_buffer.deinit(device);

        result.drawable_buffer = try .init(device, max_drawables_count, .storage);
        errdefer result.drawable_buffer.deinit(device);

        result.drawcall_buffer = try .init(device, max_drawables_count, .indirect);
        errdefer result.drawcall_buffer.deinit(device);

        return result;
    }

    pub fn deinit(self: *Renderer, device: *c.SDL_GPUDevice) void {
        for (self.textures) |p| if (p != null) c.SDL_ReleaseGPUTexture(device, p.?);
        for (self.samplers) |p| if (p != null) c.SDL_ReleaseGPUSampler(device, p.?);
        self.drawcall_buffer.deinit(device);
        self.drawable_buffer.deinit(device);
        self.index_buffer.deinit(device);
        self.vertex_buffer.deinit(device);
        c.SDL_ReleaseGPUGraphicsPipeline(device, self.pipeline);
    }

    pub fn startFrame(self: *Renderer, device: *c.SDL_GPUDevice) !void {
        try self.vertex_buffer.startMap(device);
        try self.index_buffer.startMap(device);
        try self.drawable_buffer.startMap(device);
        try self.drawcall_buffer.startMap(device);
    }

    pub fn endFrame(self: *Renderer, device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
        self.vertex_buffer.endMap(device);
        self.index_buffer.endMap(device);
        self.drawable_buffer.endMap(device);
        self.drawcall_buffer.endMap(device);

        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(cmdbuf));
        self.vertex_buffer.upload(copy_pass);
        self.index_buffer.upload(copy_pass);
        self.drawable_buffer.upload(copy_pass);
        self.drawcall_buffer.upload(copy_pass);
        c.SDL_EndGPUCopyPass(copy_pass);

        const color_target_info: c.SDL_GPUColorTargetInfo = .{
            .texture = swapchain_texture,
            // TODO: configurable
            .clear_color = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1.0 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        };

        const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);

        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &.{
            .buffer = self.vertex_buffer.sdl_buffer,
            .offset = 0,
        }, 1);
        c.SDL_BindGPUIndexBuffer(render_pass, &.{
            .buffer = self.index_buffer.sdl_buffer,
            .offset = 0,
        }, c.SDL_GPU_INDEXELEMENTSIZE_16BIT);
        c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &[1]*c.SDL_GPUBuffer{
            self.drawable_buffer.sdl_buffer,
        }, 1);

        var sampler_bindings: [texture_count]c.SDL_GPUTextureSamplerBinding = undefined;
        for (&sampler_bindings, self.textures, self.samplers) |*binding, texture, sampler| {
            binding.* = .{ .texture = texture, .sampler = sampler };
        }
        c.SDL_BindGPUFragmentSamplers(render_pass, 0, &sampler_bindings, texture_count);

        c.SDL_DrawGPUIndexedPrimitivesIndirect(
            render_pass,
            self.drawcall_buffer.sdl_buffer,
            0,
            @intCast(self.drawcall_buffer.pushed_count),
        );

        c.SDL_EndGPURenderPass(render_pass);
    }

    const ModelInfo = struct {
        num_indices: u32,
        first_index: u32,
        vertex_offset: i32,
    };

    const Texture = struct {
        w: u32,
        h: u32,
        pixels: []const [4]u8,
    };

    pub fn setTextureFromBmp(self: *Renderer, device: *c.SDL_GPUDevice, id: usize, comptime bmp_path: []const u8, sampler_info: *const c.SDL_GPUSamplerCreateInfo) !void {
        const bmp_bytes = @embedFile(bmp_path);
        const bmp_io = try errify(c.SDL_IOFromConstMem(bmp_bytes.ptr, bmp_bytes.len));
        const bmp_surface = try errify(c.SDL_LoadBMP_IO(bmp_io, true));
        defer c.SDL_DestroySurface(bmp_surface);

        try self.setTexture(device, id, .{
            .w = @intCast(bmp_surface.*.w),
            .h = @intCast(bmp_surface.*.h),
            .pixels = @as([*]const [4]u8, @ptrCast(bmp_surface.*.pixels))[0..@intCast(bmp_surface.*.w * bmp_surface.*.h)],
        }, sampler_info);
    }

    pub fn setTexture(self: *Renderer, device: *c.SDL_GPUDevice, id: usize, data: Texture, sampler_info: *const c.SDL_GPUSamplerCreateInfo) !void {
        assert(0 < id and id <= texture_count);
        assert(data.w * data.h == data.pixels.len);

        const sampler = try errify(c.SDL_CreateGPUSampler(device, sampler_info));
        errdefer c.SDL_ReleaseGPUSampler(device, sampler);

        const texture = try errify(c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .width = data.w,
            .height = data.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        }));
        errdefer c.SDL_ReleaseGPUTexture(device, texture);

        const transfer_buffer = try errify(c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = data.w * data.h * 4,
        }));
        defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

        const ptr: [*][4]u8 = @ptrCast(@alignCast(try errify(
            c.SDL_MapGPUTransferBuffer(device, transfer_buffer, false),
        )));
        @memcpy(ptr[0 .. data.w * data.h], data.pixels);
        c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

        const upload_cmd_buf = try errify(c.SDL_AcquireGPUCommandBuffer(device));

        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(upload_cmd_buf));
        c.SDL_UploadToGPUTexture(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = 0,
        }, &.{
            .texture = texture,
            .w = data.w,
            .h = data.h,
            .d = 1,
        }, false);
        c.SDL_EndGPUCopyPass(copy_pass);

        try errify(c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf));

        if (self.textures[id - 1] != null or self.samplers[id - 1] != null) @panic("TODO");
        self.textures[id - 1] = texture;
        self.samplers[id - 1] = sampler;
    }

    pub fn addModel(self: *Renderer, vertices: []const Vertex, indices: []const [3]u16) !ModelInfo {
        const result: ModelInfo = .{
            .num_indices = @intCast(indices.len * 3),
            .first_index = @intCast(self.index_buffer.pushed_count * 3),
            .vertex_offset = @intCast(self.vertex_buffer.pushed_count),
        };

        try self.vertex_buffer.push(vertices);
        try self.index_buffer.push(indices);

        return result;
    }

    pub fn addDrawable(self: *Renderer, drawable: Drawable, model_info: ModelInfo) !void {
        assert(self.drawable_buffer.pushed_count == self.drawcall_buffer.pushed_count);
        const drawable_id = self.drawcall_buffer.pushed_count;

        try self.drawable_buffer.push(&.{drawable});
        try self.drawcall_buffer.push(&.{.{
            .num_indices = model_info.num_indices,
            .num_instances = 1,
            .first_index = model_info.first_index,
            .vertex_offset = model_info.vertex_offset,
            .first_instance = @intCast(drawable_id),
        }});
    }
};

var renderer: Renderer = undefined;
pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
    renderer = try .init(device, window);

    try renderer.setTexture(device, 1, .{ .w = 2, .h = 2, .pixels = &.{
        .{ 255, 255, 255, 255 },
        .{ 255, 0, 0, 255 },
        .{ 0, 255, 0, 255 },
        .{ 0, 0, 255, 255 },
    } }, &.{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    });

    try renderer.setTextureFromBmp(device, 2, "ravioli.bmp", &.{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    });
}

pub fn draw(device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
    try renderer.startFrame(device);

    const tri = try renderer.addModel(&.{
        .{ .relative_pos = .{ -0.3, -0.3 }, .uv = .{ 0, 1 } },
        .{ .relative_pos = .{ 0.3, -0.3 }, .uv = .{ 1, 1 } },
        .{ .relative_pos = .{ 0.0, 0.3 }, .uv = .{ 0.5, 0 } },
    }, &.{.{ 0, 1, 2 }});

    try renderer.addDrawable(.{
        .camera_center = .{ 0, 0 },
        .camera_axis_x = .{ 1, 0 },
        .camera_axis_y = .{ 0, 1 },
        .color = .{ 1, 1, 1, 1 },
        .texture_id = 0,
        .material_id = 0,
    }, tri);

    const quad = try renderer.addModel(&.{
        .{ .relative_pos = .{ 0, 0 }, .uv = .{ 0, 0 } },
        .{ .relative_pos = .{ 1, 0 }, .uv = .{ 1, 0 } },
        .{ .relative_pos = .{ 0, 1 }, .uv = .{ 0, 1 } },
        .{ .relative_pos = .{ 1, 1 }, .uv = .{ 1, 1 } },
    }, &.{ .{ 0, 1, 2 }, .{ 3, 2, 1 } });

    try renderer.addDrawable(.{
        .camera_center = .{ 0.0, -0.2 },
        .camera_axis_x = .{ 0.5, 0 },
        .camera_axis_y = .{ 0, 0.5 },
        .color = .{ 1, 0.5, 0.2, 1 },
        .texture_id = 2,
        .material_id = 0,
    }, quad);

    try renderer.addDrawable(.{
        .camera_center = .{ 0.4, 0.3 },
        .camera_axis_x = .{ 0.5, 0 },
        .camera_axis_y = .{ 0, 0.5 },
        .color = .{ 0.5, 1, 0.1, 1 },
        .texture_id = 1,
        .material_id = 0,
    }, tri);

    try renderer.endFrame(device, cmdbuf, swapchain_texture);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    renderer.deinit(device);
}

fn hasNoImplicitPadding(comptime T: type) bool {
    var sum_size = @as(usize, 0);

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.is_comptime) continue;
        sum_size += @sizeOf(field.type);
    }

    return @sizeOf(T) == sum_size;
}

test hasNoImplicitPadding {
    try std.testing.expect(!hasNoImplicitPadding(struct {
        foo: [3]u8,
        bar: f32,
    }));
}

// based on https://maraneshi.github.io/HLSL-ConstantBufferLayoutVisualizer
// For some reason, the structured buffers produced by shadercross follow the Constant Buffer packing rules
// so ignore the Addendum 6 of that article.
fn validateHlslStructuredBuffer(comptime T: type) void {
    // 1. All scalar types are self-aligned, i.e. their type alignment requirement is equal to their size.
    // Additionally, bool has a size of 4 bytes
    // 1a. Vectors and matrices are aligned according to their scalar component type.
    // 2. A member can't cross a 16-byte row.
    // 3 and 4. rules about HLSL arrays, matrices, and structs, don't allow them for now

    comptime assert(@typeInfo(T).@"struct".layout != .auto);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.startsWith(u8, field.name, "_pad")) continue;
        switch (@typeInfo(field.type)) {
            else => @compileError(std.fmt.comptimePrint("type {} not supported", .{field.type})),
            .@"struct" => @compileError("TODO: support structs"),
            .vector => @compileError("TODO: support vectors"),
            .bool => @compileError("bools are forbidden, use a u32 explicitly"),
            .array => |info| switch (@typeInfo(info.child)) {
                else => @compileError(std.fmt.comptimePrint("TODO: support arrays of child type {}", .{field.type})),
                .int, .float => {},
            },
            .int, .float => {},
        }

        const byte_start = @offsetOf(T, field.name);
        const byte_end = byte_start + @sizeOf(field.type);
        const row_start = @divFloor(byte_start, 16);
        if ((byte_end - 16 * row_start) > 16 and @mod(byte_start, 16) != 0) {
            @compileError(std.fmt.comptimePrint("field {s} of type {} crosses a 16-byte boundary while not being 16-byte aligned", .{ field.name, field.type }));
        }
    }

    if (@mod(@sizeOf(T), 16) != 0) {
        @compileError(std.fmt.comptimePrint("struct size should be a multiple of 16; missing {d} bytes", .{16 - @mod(@sizeOf(T), 16)}));
    }
}

test validateHlslStructuredBuffer {
    comptime validateHlslStructuredBuffer(extern struct { a: f32, b: [3]f32 });
}
