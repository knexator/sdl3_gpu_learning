const std = @import("std");
const c = @import("c");

const main = @import("main.zig");
const loadShader = main.loadShader;
const errify = main.errify;

var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffer: *c.SDL_GPUBuffer = undefined;
var index_buffer: *c.SDL_GPUBuffer = undefined;
var texture: *c.SDL_GPUTexture = undefined;
var sampler: *c.SDL_GPUSampler = undefined;

const PositionTextureVertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
};

pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
    if (true) { // build pipeline
        const vertex_shader = try loadShader(
            "TexturedQuad.vert",
            0,
            0,
            0,
            0,
        );
        defer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const fragment_shader = try loadShader(
            "TexturedQuad.frag",
            1,
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
            // This is set up to match the vertex shader layout!
            .vertex_input_state = .{
                .num_vertex_buffers = 1,
                .vertex_buffer_descriptions = &c.SDL_GPUVertexBufferDescription{
                    .slot = 0,
                    .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                    .instance_step_rate = 0,
                    .pitch = @sizeOf(PositionTextureVertex),
                },
                .num_vertex_attributes = 2,
                .vertex_attributes = &[2]c.SDL_GPUVertexAttribute{ .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                    .location = 0,
                    .offset = 0,
                }, .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                    .location = 1,
                    .offset = @sizeOf([3]f32),
                } },
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
        };

        pipeline = try errify(c.SDL_CreateGPUGraphicsPipeline(device, &pipeline_create_info));
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    }

    sampler = try errify(c.SDL_CreateGPUSampler(device, &.{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    }));
    errdefer c.SDL_ReleaseGPUSampler(device, sampler);

    const image_bmp = @embedFile("ravioli.bmp");
    const image_bmp_io = try errify(c.SDL_IOFromConstMem(image_bmp, image_bmp.len));
    const imageData = try errify(c.SDL_LoadBMP_IO(image_bmp_io, true));
    defer c.SDL_DestroySurface(imageData);
    const image_w: u32 = @intCast(imageData.*.w);
    const image_h: u32 = @intCast(imageData.*.h);

    texture = try errify(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .width = image_w,
        .height = image_h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
    }));
    errdefer c.SDL_ReleaseGPUTexture(device, texture);

    const textureTransferBuffer = try errify(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = image_w * image_h * 4,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, textureTransferBuffer);

    if (true) { // transfer texture data
        const textureTransferPtr: [*c]u8 = @ptrCast(@alignCast(try errify(
            c.SDL_MapGPUTransferBuffer(device, textureTransferBuffer, false),
        )));
        @memcpy(textureTransferPtr[0 .. image_w * image_h * 4], @as([*c]u8, @ptrCast(imageData.*.pixels)));
        c.SDL_UnmapGPUTransferBuffer(device, textureTransferBuffer);
    }

    const vertexBufferSize = @sizeOf(PositionTextureVertex) * 4;
    vertex_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = vertexBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

    const indexBufferSize = @sizeOf(u16) * 6;
    index_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
        .size = indexBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, index_buffer);

    // Set the buffer data
    const transferBuffer: *c.SDL_GPUTransferBuffer = try errify(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = vertexBufferSize + indexBufferSize,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transferBuffer);

    if (true) { // map and unmap
        const transferData: [*c]PositionTextureVertex = @ptrCast(@alignCast(try errify(
            c.SDL_MapGPUTransferBuffer(device, transferBuffer, false),
        )));
        defer c.SDL_UnmapGPUTransferBuffer(device, transferBuffer);

        transferData[0] = .{ .pos = .{ -0.5, -0.5, 0 }, .uv = .{ 0, 0 } };
        transferData[1] = .{ .pos = .{ 0.5, -0.5, 0 }, .uv = .{ 1, 0 } };
        transferData[2] = .{ .pos = .{ 0.5, 0.5, 0 }, .uv = .{ 1, 1 } };
        transferData[3] = .{ .pos = .{ -0.5, 0.5, 0 }, .uv = .{ 0, 1 } };

        const indexData: [*c]u16 = @ptrCast(transferData[4..]);
        indexData[0] = 0;
        indexData[1] = 1;
        indexData[2] = 2;
        indexData[3] = 0;
        indexData[4] = 2;
        indexData[5] = 3;

        const indexedDrawCommand: [*c]c.SDL_GPUIndexedIndirectDrawCommand = @ptrCast(@alignCast(indexData[6..]));
        indexedDrawCommand[0] = .{
            .num_indices = 6,
            .num_instances = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        };

        const drawCommands: [*c]c.SDL_GPUIndirectDrawCommand = @ptrCast(@alignCast(indexedDrawCommand[1..]));
        drawCommands[0] = .{
            .num_vertices = 3,
            .num_instances = 1,
            .first_vertex = 4,
            .first_instance = 0,
        };
        drawCommands[1] = .{
            .num_vertices = 3,
            .num_instances = 1,
            .first_vertex = 7,
            .first_instance = 0,
        };
    }

    const upload_cmd_buf = try errify(c.SDL_AcquireGPUCommandBuffer(device));

    if (true) { // copy pass
        const copy_pass = try errify(c.SDL_BeginGPUCopyPass(upload_cmd_buf));
        defer c.SDL_EndGPUCopyPass(copy_pass);

        c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transferBuffer,
            .offset = 0,
        }, &.{
            .buffer = vertex_buffer,
            .offset = 0,
            .size = vertexBufferSize,
        }, false);

        c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transferBuffer,
            .offset = vertexBufferSize,
        }, &.{
            .buffer = index_buffer,
            .offset = 0,
            .size = indexBufferSize,
        }, false);

        c.SDL_UploadToGPUTexture(copy_pass, &.{
            .transfer_buffer = textureTransferBuffer,
            .offset = 0,
        }, &.{
            .texture = texture,
            .w = image_w,
            .h = image_h,
            .d = 1,
        }, false);
    }

    try errify(c.SDL_SubmitGPUCommandBuffer(upload_cmd_buf));
}

pub fn draw(device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
    _ = device;
    const color_target_info: c.SDL_GPUColorTargetInfo = .{
        .texture = swapchain_texture,
        .clear_color = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1.0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);

    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
    c.SDL_BindGPUVertexBuffers(render_pass, 0, &.{
        .buffer = vertex_buffer,
        .offset = 0,
    }, 1);
    c.SDL_BindGPUIndexBuffer(render_pass, &.{
        .buffer = index_buffer,
        .offset = 0,
    }, c.SDL_GPU_INDEXELEMENTSIZE_16BIT);
    c.SDL_BindGPUFragmentSamplers(render_pass, 0, &.{
        .texture = texture,
        .sampler = sampler,
    }, 1);
    c.SDL_DrawGPUIndexedPrimitives(render_pass, 6, 1, 0, 0, 0);

    c.SDL_EndGPURenderPass(render_pass);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    c.SDL_ReleaseGPUTexture(device, texture);
    c.SDL_ReleaseGPUSampler(device, sampler);
    c.SDL_ReleaseGPUBuffer(device, index_buffer);
    c.SDL_ReleaseGPUBuffer(device, vertex_buffer);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}
