const std = @import("std");
const c = @import("c");

const main = @import("main.zig");
const loadShader = main.loadShader;
const errify = main.errify;

var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffer: *c.SDL_GPUBuffer = undefined;
var index_buffer: *c.SDL_GPUBuffer = undefined;
var draw_buffer: *c.SDL_GPUBuffer = undefined;

const PositionColorVertex = extern struct {
    pos: [3]f32,
    color: [4]u8,
};

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

pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
    if (true) { // build pipeline
        const vertex_shader = try loadShader(
            "PositionColor.vert",
            0,
            0,
            0,
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
            // This is set up to match the vertex shader layout!
            .vertex_input_state = .{
                .num_vertex_buffers = 1,
                .vertex_buffer_descriptions = &c.SDL_GPUVertexBufferDescription{
                    .slot = 0,
                    .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                    .instance_step_rate = 0,
                    .pitch = @sizeOf(PositionColorVertex),
                },
                .num_vertex_attributes = 2,
                .vertex_attributes = &[2]c.SDL_GPUVertexAttribute{ .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                    .location = 0,
                    .offset = 0,
                }, .{
                    .buffer_slot = 0,
                    .format = c.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM,
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

    const vertexBufferSize = @sizeOf(PositionColorVertex) * 10;
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

    const drawBufferSize = (@sizeOf(c.SDL_GPUIndexedIndirectDrawCommand) * 1) + (@sizeOf(c.SDL_GPUIndirectDrawCommand) * 2);
    draw_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_INDIRECT,
        .size = drawBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, draw_buffer);

    // Set the buffer data
    const transferBuffer: *c.SDL_GPUTransferBuffer = try errify(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = vertexBufferSize + indexBufferSize + drawBufferSize,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transferBuffer);

    if (true) { // map and unmap
        const transferData: [*c]PositionColorVertex = @ptrCast(@alignCast(try errify(
            c.SDL_MapGPUTransferBuffer(device, transferBuffer, false),
        )));
        defer c.SDL_UnmapGPUTransferBuffer(device, transferBuffer);

        transferData[0] = .{ .pos = .{ -1, -1, 0 }, .color = .{ 255, 0, 0, 255 } };
        transferData[1] = .{ .pos = .{ 1, -1, 0 }, .color = .{ 0, 255, 0, 255 } };
        transferData[2] = .{ .pos = .{ 1, 1, 0 }, .color = .{ 0, 0, 255, 255 } };
        transferData[3] = .{ .pos = .{ -1, 1, 0 }, .color = .{ 255, 255, 255, 255 } };

        transferData[4] = .{ .pos = .{ 1, -1, 0 }, .color = .{ 0, 255, 0, 255 } };
        transferData[5] = .{ .pos = .{ 0, -1, 0 }, .color = .{ 0, 0, 255, 255 } };
        transferData[6] = .{ .pos = .{ 0.5, 1, 0 }, .color = .{ 255, 0, 0, 255 } };
        transferData[7] = .{ .pos = .{ -1, -1, 0 }, .color = .{ 0, 255, 0, 255 } };
        transferData[8] = .{ .pos = .{ 0, -1, 0 }, .color = .{ 0, 0, 255, 255 } };
        transferData[9] = .{ .pos = .{ -0.5, 1, 0 }, .color = .{ 255, 0, 0, 255 } };

        const indexData: [*c]u16 = @ptrCast(transferData[10..]);
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

        c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transferBuffer,
            .offset = vertexBufferSize + indexBufferSize,
        }, &.{
            .buffer = draw_buffer,
            .offset = 0,
            .size = drawBufferSize,
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
    c.SDL_DrawGPUIndexedPrimitivesIndirect(render_pass, draw_buffer, 0, 1);
    c.SDL_DrawGPUPrimitivesIndirect(render_pass, draw_buffer, @sizeOf(c.SDL_GPUIndexedIndirectDrawCommand), 2);

    c.SDL_EndGPURenderPass(render_pass);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    c.SDL_ReleaseGPUBuffer(device, draw_buffer);
    c.SDL_ReleaseGPUBuffer(device, index_buffer);
    c.SDL_ReleaseGPUBuffer(device, vertex_buffer);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}
