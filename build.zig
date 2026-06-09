const std = @import("std");

// https://codeberg.org/ziglang/zig/pulls/31892

// https://moonside.games/posts/sdl-gpu-sprite-batcher/
// https://github.com/TheSpydog/SDL_gpu_examples/blob/main/Examples/ClearScreen.c

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_lib = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    }).artifact("SDL3");

    const tc_dep = b.dependency("translate_c", .{});
    const sdl_lib_zig: @import("translate_c").Translator = .init(tc_dep, .{
        .target = target,
        .optimize = optimize,
        .default_init = true,
        .c_source_file = b.addWriteFiles().add("wrapper.h",
            \\#define SDL_DISABLE_OLD_NAMES
            \\#include <SDL3/SDL.h>
            \\#include <SDL3/SDL_revision.h>
            \\#define SDL_MAIN_HANDLED
            \\#include <SDL3/SDL_main.h>
            \\
        ),
    });
    sdl_lib_zig.linkLibrary(sdl_lib);

    const app_exe = b.addExecutable(.{
        .name = "gamename",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "c",
                    .module = sdl_lib_zig.mod,
                },
            },
        }),
    });

    b.installArtifact(app_exe);

    const shadercross_exe = switch (b.graph.host.result.os.tag) {
        .windows => b.dependency("shadercross_windows", .{}).path("bin/shadercross.exe"),
        .linux => b.dependency("shadercross_linux", .{}).path("bin/shadercross"),
        else => |t| std.debug.panic("unsupported os: {s}", .{@tagName(t)}),
    };
    const shaders: []const []const u8 = &.{
        "UVColor.frag",
        "PullSpriteBatch.vert",
        "PositionColor.vert",
        "PositionColorInstanced.vert",
        "PositionColorTransform.vert",
        "PositionColorMine.vert",
        "SolidColor.frag",
    };
    inline for (shaders) |shader| {
        const compile_shader_cmd = std.Build.Step.Run.create(b, "compile shader");
        compile_shader_cmd.addFileArg(shadercross_exe);
        compile_shader_cmd.addFileArg(b.path("shaders/" ++ shader ++ ".hlsl"));
        compile_shader_cmd.addArg("--output");
        const compiled_shader = compile_shader_cmd.addOutputFileArg(shader ++ ".spv");

        app_exe.root_module.addAnonymousImport(shader, .{
            .root_source_file = compiled_shader,
        });
    }

    const run_app = b.addRunArtifact(app_exe);
    if (b.args) |args| run_app.addArgs(args);
    // run_app.addPassthruArgs();
    run_app.step.dependOn(b.getInstallStep());

    const run = b.step("run", "Run the app");
    run.dependOn(&run_app.step);
}
