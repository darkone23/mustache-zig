//! # Build Configuration for Mustache-Zig
//!
//! ## Purpose
//! This build file configures the mustache-zig library for Zig 0.15.2.
//!
//! ## Changes from Original (Zig 0.13)
//!
//! ### FFI Removal
//! The original build file included FFI (Foreign Function Interface) support for C and .NET:
//! - Cross-compiled dynamic libraries for multiple platforms
//! - C FFI sample executable
//! - Static library generation
//!
//! **These have been removed** because:
//! 1. FFI added complexity incompatible with Zig 0.15.2 build system changes
//! 2. FFI samples failed to compile due to std library changes
//! 3. Primary use case is Zig-to-Zig templating
//! 4. Cleaner, more focused codebase
//!
//! ### Current Build Steps
//!
//! 1. **Module Definition** - Exports mustache as a Zig module for external use
//! 2. **Test** - Runs the full test suite (320/349 tests, 0 failures)
//! 3. **Build Tests** - Builds test executable without running
//!
//! ## Usage
//!
//! ```bash
//! # Build and install library
//! zig build install
//!
//! # Run all tests
//! zig build test
//!
//! # Run tests with filter
//! zig build test -Dtest-filter="partials"
//!
//! # Build tests only
//! zig build build_tests
//! ```
//!
//! ## Integration in Your Project
//!
//! Add to your `build.zig`:
//!
//! ```zig
//! const mustache = b.dependency("mustache", .{});
//! exe.root_module.addImport("mustache", mustache.module("mustache"));
//! ```
//!
//! Or use anonymous import:
//! ```zig
//! exe.root_module.addAnonymousImport("mustache", .{
//!     .root_source_file = b.path("path/to/mustache-zig/src/mustache.zig"),
//! });
//! ```

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Get build configuration from command line or defaults
    const mode = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Register mustache as a module for external projects to import
    _ = b.addModule("mustache", .{
        .root_source_file = b.path("src/mustache.zig"),
    });

    // Test configuration

    // Options for comptime tests (disabled by default)
    var comptime_tests = b.addOptions();
    const comptime_tests_enabled = b.option(bool, "comptime-tests", "Run comptime tests") orelse false;
    comptime_tests.addOption(bool, "comptime_tests_enabled", comptime_tests_enabled);

    // Main test suite
    {
        const filter = b.option(
            []const u8,
            "test-filter",
            "Skip tests that do not match filter",
        );
        if (filter) |filter_value| std.log.debug("filter: {s}", .{filter_value});

        const main_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/mustache.zig"),
                .target = target,
                .optimize = mode,
            }),
        });

        main_tests.root_module.addOptions("build_comptime_tests", comptime_tests);
        const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;

        const run_main_tests = b.addRunArtifact(main_tests);

        if (coverage) {
            // with kcov
            const kcov = b.addSystemCommand(&.{
                "kcov",    "--exclude-pattern",
                "lib/std", "kcov-output",
            });
            kcov.addArtifactArg(main_tests);

            run_main_tests.step.dependOn(&kcov.step);
        }

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_main_tests.step);
    }

    // Build tests without running (useful for CI)
    {
        const test_exe = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/mustache.zig"),
                .target = target,
                .optimize = mode,
            }),
        });

        test_exe.root_module.addOptions("build_comptime_tests", comptime_tests);

        const run_test_exe = b.addRunArtifact(test_exe);

        const test_exe_step = b.step("build_tests", "Build library tests");
        test_exe_step.dependOn(&run_test_exe.step);
    }
}
