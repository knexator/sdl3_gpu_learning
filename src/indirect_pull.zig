const std = @import("std");
const c = @import("c");

const main = @import("main.zig");
const loadShader = main.loadShader;
const errify = main.errify;

// NOT WORKING! seems like indexing issue

var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffer: *c.SDL_GPUBuffer = undefined;
var index_buffer: *c.SDL_GPUBuffer = undefined;
var draw_buffer: *c.SDL_GPUBuffer = undefined;
var things_buffer: *c.SDL_GPUBuffer = undefined;

const VertexData = extern struct {
    pos: [3]f32,
    // TODO: have this be [4]u8 and figure out how to transform it
    color: [4]f32,
};

const ThingData = extern struct {
    offset: [2]f32,
};

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

    const vertexBufferSize = @sizeOf(VertexData) * 4;
    vertex_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
        .size = vertexBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, vertex_buffer);

    const indexBufferSize = @sizeOf(u16) * 6;
    index_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
        .size = indexBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, index_buffer);

    const drawBufferSize = (@sizeOf(c.SDL_GPUIndexedIndirectDrawCommand) * 2);
    draw_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_INDIRECT,
        .size = drawBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, draw_buffer);

    const thingBufferSize = @sizeOf(ThingData) * 3;
    things_buffer = try errify(c.SDL_CreateGPUBuffer(device, &.{
        .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
        .size = thingBufferSize,
    }));
    errdefer c.SDL_ReleaseGPUBuffer(device, things_buffer);

    // Set the buffer data
    const transferBuffer: *c.SDL_GPUTransferBuffer = try errify(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = vertexBufferSize + indexBufferSize + drawBufferSize + thingBufferSize,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transferBuffer);

    if (true) { // map and unmap
        const transferData: [*c]VertexData = @ptrCast(@alignCast(try errify(
            c.SDL_MapGPUTransferBuffer(device, transferBuffer, false),
        )));
        defer c.SDL_UnmapGPUTransferBuffer(device, transferBuffer);

        transferData[0] = .{ .pos = .{ -0.5, -0.5, 0 }, .color = .{ 1, 0, 0, 1 } };
        transferData[1] = .{ .pos = .{ 0.5, -0.5, 0 }, .color = .{ 0, 1, 0, 1 } };
        transferData[2] = .{ .pos = .{ 0.5, 0.5, 0 }, .color = .{ 0, 0, 1, 1 } };
        transferData[3] = .{ .pos = .{ -0.5, 0.5, 0 }, .color = .{ 1, 1, 1, 1 } };

        const indexData: [*c][3]u16 = @ptrCast(transferData[4..]);
        indexData[0] = .{ 0, 1, 2 };
        indexData[1] = .{ 0, 2, 3 };

        const indexedDrawCommand: [*c]c.SDL_GPUIndexedIndirectDrawCommand = @ptrCast(@alignCast(indexData[2..]));
        indexedDrawCommand[0] = .{
            .num_indices = 6,
            .num_instances = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        };
        indexedDrawCommand[1] = .{
            .num_indices = 6,
            .num_instances = 2,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 1,
        };

        const thingData: [*c]ThingData = @ptrCast(@alignCast(indexedDrawCommand[2..]));
        thingData[0] = .{ .offset = .{ 0.25, 0.25 } };
        thingData[1] = .{ .offset = .{ 0, -0.25 } };
        thingData[2] = .{ .offset = .{ -0.8, 0 } };
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

        c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transferBuffer,
            .offset = vertexBufferSize + indexBufferSize + drawBufferSize,
        }, &.{
            .buffer = things_buffer,
            .offset = 0,
            .size = thingBufferSize,
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
    c.SDL_BindGPUVertexStorageBuffers(
        render_pass,
        0,
        &@as([2]*c.SDL_GPUBuffer, .{ vertex_buffer, things_buffer }),
        2,
    );
    c.SDL_BindGPUIndexBuffer(render_pass, &.{
        .buffer = index_buffer,
        .offset = 0,
    }, c.SDL_GPU_INDEXELEMENTSIZE_16BIT);
    c.SDL_DrawGPUIndexedPrimitivesIndirect(render_pass, draw_buffer, 0, 2);

    c.SDL_EndGPURenderPass(render_pass);
}

pub fn deinit(device: *c.SDL_GPUDevice) void {
    c.SDL_ReleaseGPUBuffer(device, things_buffer);
    c.SDL_ReleaseGPUBuffer(device, draw_buffer);
    c.SDL_ReleaseGPUBuffer(device, index_buffer);
    c.SDL_ReleaseGPUBuffer(device, vertex_buffer);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
}
