pub fn build(b: *std.Build) void {
    b.getInstallStep().dependOn(&addPythonArchive(b, .x86_64).step);
    // b.getInstallStep().dependOn(&addPythonArchive(b, .aarch64).step);
}

fn addPythonArchive(b: *std.Build, target: LinuxTarget) *std.Build.Step.InstallFile {
    const python_dir = addPython3(b, target.base(), .ReleaseSafe);
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const archive_basename = b.fmt("python-3.11.5-{s}.tar.gz", .{@tagName(target)});
    const archive = tar.addOutputFileArg(archive_basename);
    tar.addArg("-C");
    tar.addDirectoryArg(python_dir);
    tar.addArg(".");
    return b.addInstallFile(archive, archive_basename);
}

fn targetOption(b: *std.Build, name: []const u8) ?[]const u8 {
    _ = b.available_options_map.get(name) orelse std.debug.panic("std.Build never added option '{s}'", .{name});
    const option_ptr = b.user_input_options.getPtr(name) orelse return null;
    return switch (option_ptr.value) {
        .scalar => |s| s,
        .flag, .list, .map, .lazy_path, .lazy_path_list => std.debug.panic(
            "expected build option '{s}' to be of type scalar (string) but it's {s}",
            .{ name, @tagName(option_ptr.value) },
        ),
    };
}

fn forwardTargetOptions(b: *std.Build, run: *std.Build.Step.Run) void {
    const names = [_][]const u8{ "target", "cpu", "ofmt", "dynamic-linker" };
    for (names) |name| {
        if (targetOption(b, name)) |value| {
            run.addArg(b.fmt("-D{s}={s}", .{ name, value }));
        }
    }
}

const LinuxTarget = enum {
    x86_64,
    aarch64,
    pub fn base(self: LinuxTarget) Target {
        return switch (self) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        };
    }
};
const Target = enum { native, std, x86_64, aarch64 };

fn addPython3(b: *std.Build, target: Target, optimize: std.builtin.OptimizeMode) std.Build.LazyPath {
    const run_build = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
    });
    run_build.addFileArg(b.path("python3/build.zig"));
    switch (target) {
        .native => {},
        .std => forwardTargetOptions(b, run_build),
        .x86_64 => run_build.addArg("-Dtarget=x86_64-linux-musl"),
        .aarch64 => run_build.addArg("-Dtarget=aarch64-linux-musl"),
    }
    run_build.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    const write_files = b.addWriteFiles();
    write_files.step.dependOn(&run_build.step);
    _ = write_files.addCopyFile(b.path("python3/zig-out/bin/cpython"), "bin/python3");
    _ = write_files.addCopyDirectory(b.path("python3/zig-out/lib"), "lib", .{});
    const empty_dir = b.addWriteFiles().getDirectory();
    _ = write_files.addCopyDirectory(empty_dir, "lib/python3.11/lib-dynload", .{});

    const install = b.addInstallDirectory(.{
        .source_dir = write_files.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "",
    });
    const name = switch (target) {
        .native => "python3-native",
        .std => "python3",
        .x86_64 => "python3-x86_64",
        .aarch64 => "python3-aarch64",
    };
    b.step(name, "").dependOn(&install.step);
    return write_files.getDirectory();
}

const ZigFetchOptions = struct {
    url: []const u8,
    hash: []const u8,
};
const ZigFetch = struct {
    step: std.Build.Step,
    url: []const u8,
    hash: []const u8,

    already_fetched: bool,
    pkg_path_dont_use_me_directly: []const u8,
    lazy_fetch_stdout: std.Build.LazyPath,
    generated_directory: std.Build.GeneratedFile,
    pub fn create(b: *std.Build, opt: ZigFetchOptions) *ZigFetch {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "fetch", opt.url });
        const fetch = b.allocator.create(ZigFetch) catch @panic("OOM");
        const pkg_path = b.pathJoin(&.{
            b.graph.global_cache_root.path.?,
            "p",
            opt.hash,
        });
        const already_fetched = if (std.fs.cwd().access(pkg_path, .{}))
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => |e| std.debug.panic("access '{s}' failed with {s}", .{ pkg_path, @errorName(e) }),
        };
        fetch.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("zig fetch {s}", .{opt.url}),
                .owner = b,
                .makeFn = make,
            }),
            .url = b.allocator.dupe(u8, opt.url) catch @panic("OOM"),
            .hash = b.allocator.dupe(u8, opt.hash) catch @panic("OOM"),
            .pkg_path_dont_use_me_directly = pkg_path,
            .already_fetched = already_fetched,
            .lazy_fetch_stdout = run.captureStdOut(),
            .generated_directory = .{
                .step = &fetch.step,
            },
        };
        if (!already_fetched) {
            fetch.step.dependOn(&run.step);
        }
        return fetch;
    }
    pub fn getLazyPath(self: *const ZigFetch) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated_directory } };
    }
    pub fn path(self: *ZigFetch, sub_path: []const u8) std.Build.LazyPath {
        return self.getLazyPath().path(self.step.owner, sub_path);
    }
    fn make(step: *std.Build.Step, opt: std.Build.Step.MakeOptions) !void {
        _ = opt;
        const b = step.owner;
        const fetch: *ZigFetch = @fieldParentPtr("step", step);
        if (!fetch.already_fetched) {
            const sha = blk: {
                var file = try std.fs.openFileAbsolute(fetch.lazy_fetch_stdout.getPath(b), .{});
                defer file.close();
                break :blk try file.readToEndAlloc(b.allocator, 999);
            };
            const sha_stripped = std.mem.trimRight(u8, sha, "\r\n");
            if (!std.mem.eql(u8, sha_stripped, fetch.hash)) return step.fail(
                "hash mismatch: declared {s} but the fetched package has {s}",
                .{ fetch.hash, sha_stripped },
            );
        }
        fetch.generated_directory.path = fetch.pkg_path_dont_use_me_directly;
    }
};

const std = @import("std");
