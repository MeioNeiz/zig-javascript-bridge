const std = @import("std");

pub fn build(b: *std.Build) void {
    /////////////////////////////////////////////////////////////
    // generate js exe
    const generate_js = b.addExecutable(.{
        .name = "generate_js",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_js.zig"),
            .target = b.graph.host,
            // Reusing this will occur more often than compiling this, as
            // it usually can be cached.  So faster execution is worth slower
            // initial build.
            .optimize = .debug,
            // .optimize = .safe,
        }),
    });
    b.installArtifact(generate_js);

    /////////////////////////////////////////////////////////////
    // module

    const zjb = b.addModule("zjb", .{
        .root_source_file = b.path("src/zjb.zig"),
    });

    /////////////////////////////////////////////////////////////
    // tests, run in node

    const test_wasm = b.addExecutable(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    test_wasm.root_module.addImport("zjb", zjb);
    test_wasm.entry = .disabled;
    test_wasm.rdynamic = true;

    const extract_test = b.addRunArtifact(generate_js);
    const extract_test_out = extract_test.addOutputFileArg("zjb.js");
    extract_test.addArg("Zjb");
    extract_test.addArtifactArg(test_wasm);
    extract_test.addArg("--loader");

    const run_test = b.addSystemCommand(&.{"node"});
    run_test.addFileArg(b.path("test/run.mjs"));
    run_test.addFileArg(extract_test_out);
    run_test.addArtifactArg(test_wasm);
    run_test.expectExitCode(0);

    const test_step = b.step("test", "Run the tests in node, which must be on PATH");
    test_step.dependOn(&run_test.step);
}
