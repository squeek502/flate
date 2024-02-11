const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "deflate",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/flate.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/flate.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const flate_module = b.addModule("flate", .{
        .root_source_file = .{ .path = "src/flate.zig" },
    });

    const binaries = [_]Binary{
        .{ .name = "gzip", .src = "bin/gzip.zig" },
        .{ .name = "gunzip", .src = "bin/gunzip.zig" },
        .{ .name = "decompress", .src = "bin/decompress.zig" },
        .{ .name = "roundtrip", .src = "bin/roundtrip.zig" },
    };
    for (binaries) |i| {
        const bin = b.addExecutable(.{
            .name = i.name,
            .root_source_file = .{ .path = i.src },
            .target = target,
            .optimize = optimize,
        });
        bin.root_module.addImport("flate", flate_module);
        b.installArtifact(bin);
    }

    // Benchmarks are embedding bin/bench_data files which has to be present.
    // There is script `get_bench_data.sh` to fill the folder. Some of those
    // files are pretty big so it is not committed to the repo. If you are
    // building many times clear your zig-cache because it can be filled with
    // lots of copies of this files embedded into binaries.
    const bench_step = b.step("bench", "Build benchhmarks");

    const benchmarks = [_]Binary{
        .{ .name = "deflate_bench", .src = "bin/deflate_bench.zig" },
        .{ .name = "inflate_bench", .src = "bin/inflate_bench.zig" },
    };
    for (benchmarks) |i| {
        var bin = b.addExecutable(.{
            .name = i.name,
            .root_source_file = .{ .path = i.src },
            .target = target,
            .optimize = optimize,
        });
        bin.root_module.addImport("flate", flate_module);
        bench_step.dependOn(&b.addInstallArtifact(bin, .{}).step);
    }

    _ = addFuzzer(b, "fuzz_decompress", &.{}, flate_module, target);
    _ = addFuzzer(b, "fuzz_roundtrip", &.{}, flate_module, target);
    _ = addFuzzer(b, "fuzz_roundtrip_store", &.{}, flate_module, target);
    _ = addFuzzer(b, "fuzz_roundtrip_huffman", &.{}, flate_module, target);

    const deflate_puff = addFuzzer(b, "fuzz_puff", &.{}, flate_module, target);
    for (&[_]*std.Build.Step.Compile{ deflate_puff.lib, deflate_puff.debug_exe }) |compile| {
        compile.addIncludePath(.{ .path = "test/puff" });
        compile.addCSourceFile(.{ .file = .{ .path = "test/puff/puff.c" } });
        compile.linkLibC();
    }
}

const Binary = struct {
    name: []const u8,
    src: []const u8,
};

fn addFuzzer(
    b: *std.Build,
    comptime name: []const u8,
    afl_clang_args: []const []const u8,
    flate: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) FuzzerSteps {
    // The library
    const fuzz_lib = b.addStaticLibrary(.{
        .name = name ++ "-lib",
        .root_source_file = .{ .path = "test/" ++ name ++ ".zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_lib.root_module.addImport("flate", flate);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.root_module.pic = true;

    // Setup the output name
    const fuzz_executable_name = name;
    const fuzz_exe_path = std.fs.path.join(b.allocator, &.{ b.cache_root.path.?, fuzz_executable_name }) catch unreachable;

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    // Add the path to the library file to afl-clang-lto's args
    fuzz_compile.addArtifactArg(fuzz_lib);
    // Custom args
    fuzz_compile.addArgs(afl_clang_args);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);
    fuzz_install.step.dependOn(&fuzz_compile.step);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step(name, "Build executable for fuzz testing '" ++ name ++ "' using afl-clang-lto");
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable(.{
        .name = name ++ "-debug",
        .root_source_file = .{ .path = "test/" ++ name ++ ".zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_debug_exe.root_module.addImport("flate", flate);

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe, .{});
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);

    return FuzzerSteps{
        .lib = fuzz_lib,
        .debug_exe = fuzz_debug_exe,
    };
}

const FuzzerSteps = struct {
    lib: *std.Build.Step.Compile,
    debug_exe: *std.Build.Step.Compile,
};
