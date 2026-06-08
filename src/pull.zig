const std = @import("std");
const c = @import("c");

const main = @import("main.zig");
const loadShader = main.loadShader;
const errify = main.errify;

var vertex_shader: *c.SDL_GPUShader = undefined;
var fragment_shader: *c.SDL_GPUShader = undefined;
var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var spritedata_buffer: *c.SDL_GPUBuffer = undefined;
var spritedata_transfer_buffer: *c.SDL_GPUTransferBuffer = undefined;
var index_buffer: *c.SDL_GPUBuffer = undefined;
var all_models_buffer: *c.SDL_GPUBuffer = undefined;

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

pub fn init(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
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
}

pub fn draw(device: *c.SDL_GPUDevice, cmdbuf: *c.SDL_GPUCommandBuffer, swapchain_texture: *c.SDL_GPUTexture) !void {
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

pub fn deinit(device: *c.SDL_GPUDevice) void {
    c.SDL_ReleaseGPUBuffer(device, index_buffer);
    c.SDL_ReleaseGPUTransferBuffer(device, spritedata_transfer_buffer);
    c.SDL_ReleaseGPUBuffer(device, spritedata_buffer);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    c.SDL_ReleaseGPUShader(device, fragment_shader);
    c.SDL_ReleaseGPUShader(device, vertex_shader);
}
