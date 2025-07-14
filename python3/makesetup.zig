const Cmdline = struct {
    srcdir: []const u8,
    // libdir: []const u8,
    // config: []const u8,
    // makepre: []const u8,
    noobjects: bool,
    doconfig: bool,
    setup_files: []const []const u8,
};

const ModuleInfo = struct {
    name: ?[]const u8 = null,
    srcs: ArrayListUnmanaged([]const u8) = .{},
    cpps: ArrayListUnmanaged([]const u8) = .{},
    libs: ArrayListUnmanaged([]const u8) = .{},
    objs: ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *ModuleInfo, allocator: std.mem.Allocator) void {
        self.srcs.deinit(allocator);
        self.cpps.deinit(allocator);
        self.libs.deinit(allocator);
        self.objs.deinit(allocator);
    }
};

const BuildState = struct {
    noobjects: bool,
    doconfig: bool,

    defs: ArrayListUnmanaged([]const u8) = .{},
    built: ArrayListUnmanaged([]const u8) = .{},
    built_shared: ArrayListUnmanaged([]const u8) = .{},
    disabled: ArrayListUnmanaged([]const u8) = .{},
    configured: ArrayListUnmanaged([]const u8) = .{},
    mods: ArrayListUnmanaged([]const u8) = .{},
    sharedmods: ArrayListUnmanaged([]const u8) = .{},
    objs: ArrayListUnmanaged([]const u8) = .{},
    libs: ArrayListUnmanaged([]const u8) = .{},
    locallibs: ArrayListUnmanaged([]const u8) = .{},
    baselibs: ArrayListUnmanaged([]const u8) = .{},
    fn deinit(self: *BuildState, allocator: std.mem.Allocator) void {
        self.defs.deinit(allocator);
        self.built.deinit(allocator);
        self.built_shared.deinit(allocator);
        self.disabled.deinit(allocator);
        self.configured.deinit(allocator);
        self.mods.deinit(allocator);
        self.sharedmods.deinit(allocator);
        self.objs.deinit(allocator);
        self.libs.deinit(allocator);
        self.locallibs.deinit(allocator);
        self.baselibs.deinit(allocator);
    }
};

fn usage() !noreturn {
    try std.io.getStdErr().writer().writeAll(
        \\usage: makesetup --source-dir srcdir [Setup] ... [-n [Setup] ...
        \\
    );
    std.process.exit(0xff);
}

// fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
//     const file = std.fs.cwd().openFile(path, .{}) catch |e| std.debug.panic(
//         "open file '{s}' failed with {s}",
//         .{ path, @errorName(e) },
//     );
//     defer file.close();
//     return file.readToEndAlloc(allocator, std.math.maxInt(usize));
// }

fn stripComments(allocator: Allocator, line: []const u8) ![]const u8 {
    // Find # character and strip everything after it
    if (std.mem.indexOf(u8, line, "#")) |pos| {
        return try allocator.dupe(u8, std.mem.trim(u8, line[0..pos], " \t"));
    }
    return try allocator.dupe(u8, std.mem.trim(u8, line, " \t"));
}

fn isEmptyLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r\n").len == 0;
}

fn basename(path: []const u8, ext: []const u8) []const u8 {
    var filename = path;
    if (std.mem.lastIndexOf(u8, path, "/")) |pos| {
        filename = path[pos + 1 ..];
    }
    if (std.mem.endsWith(u8, filename, ext)) {
        return filename[0 .. filename.len - ext.len];
    }
    return filename;
}

fn dirname(path: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, path, "/")) |pos| {
        return path[0..pos];
    }
    return ".";
}

fn processLine(
    allocator: Allocator,
    line: []const u8,
    srcdir: []const u8,
    state: *BuildState,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    // Handle variable definitions
    if (std.mem.indexOf(u8, trimmed, "=")) |_| {
        const def = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
        try state.defs.insert(allocator, 0, def);
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "include ")) {
        const def = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
        try state.defs.insert(allocator, 0, def);
        return;
    }

    // Handle special markers
    if (std.mem.eql(u8, trimmed, "*noobjects*")) {
        if (!state.noobjects) {
            state.locallibs = state.libs;
            state.libs = .{};
        }
        state.noobjects = true;
        return;
    } else if (std.mem.eql(u8, trimmed, "*doconfig*")) {
        state.doconfig = true;
        return;
    } else if (std.mem.eql(u8, trimmed, "*static*")) {
        state.doconfig = true;
        return;
    } else if (std.mem.eql(u8, trimmed, "*noconfig*")) {
        state.doconfig = false;
        return;
    } else if (std.mem.eql(u8, trimmed, "*shared*")) {
        state.doconfig = false;
        return;
    } else if (std.mem.eql(u8, trimmed, "*disabled*")) {
        // Handle disabled modules
        return;
    }

    // Parse module line
    var module_info: ModuleInfo = .{};
    defer module_info.deinit(allocator);

    var tokens = std.mem.splitScalar(u8, trimmed, ' ');
    var skip_next = false;
    var skip_type: []const u8 = "";

    while (tokens.next()) |token| {
        if (token.len == 0) continue;

        if (skip_next) {
            if (std.mem.eql(u8, skip_type, "libs")) {
                module_info.libs.append(allocator, token) catch |e| oom(e);
            } else if (std.mem.eql(u8, skip_type, "cpps")) {
                module_info.cpps.append(allocator, token) catch |e| oom(e);
            } else if (std.mem.eql(u8, skip_type, "srcs")) {
                module_info.srcs.append(allocator, token) catch |e| oom(e);
            }
            skip_next = false;
            continue;
        }

        if (std.mem.eql(u8, token, "-framework")) {
            module_info.libs.append(allocator, token) catch |e| oom(e);
            skip_next = true;
            skip_type = "libs";
        } else if (std.mem.startsWith(u8, token, "-I") or
            std.mem.startsWith(u8, token, "-D") or
            std.mem.startsWith(u8, token, "-U") or
            std.mem.startsWith(u8, token, "-C") or
            std.mem.startsWith(u8, token, "-f") or
            std.mem.startsWith(u8, token, "-F"))
        {
            module_info.cpps.append(allocator, token) catch |e| oom(e);
        } else if (std.mem.eql(u8, token, "-Xcompiler")) {
            skip_next = true;
            skip_type = "cpps";
        } else if (std.mem.eql(u8, token, "-Xlinker") or
            std.mem.eql(u8, token, "-rpath") or
            std.mem.eql(u8, token, "--rpath"))
        {
            try module_info.libs.append(allocator, token);
            skip_next = true;
            skip_type = "libs";
        } else if (std.mem.startsWith(u8, token, "-A") or
            std.mem.startsWith(u8, token, "-Z") or
            std.mem.startsWith(u8, token, "-l"))
        {
            try module_info.libs.append(allocator, token);
        } else if (std.mem.endsWith(u8, token, ".a") or
            std.mem.endsWith(u8, token, ".so") or
            std.mem.endsWith(u8, token, ".sl") or
            std.mem.endsWith(u8, token, ".def") or
            (std.mem.startsWith(u8, token, "/") and std.mem.endsWith(u8, token, ".o")))
        {
            try module_info.libs.append(allocator, token);
        } else if (std.mem.endsWith(u8, token, ".o")) {
            const src = try std.fmt.allocPrint(allocator, "{s}.c", .{basename(token, ".o")});
            try module_info.srcs.append(allocator, src);
        } else if (std.mem.endsWith(u8, token, ".c") or
            std.mem.endsWith(u8, token, ".C") or
            std.mem.endsWith(u8, token, ".m") or
            std.mem.endsWith(u8, token, ".cc") or
            std.mem.endsWith(u8, token, ".c++") or
            std.mem.endsWith(u8, token, ".cxx") or
            std.mem.endsWith(u8, token, ".cpp"))
        {
            try module_info.srcs.append(allocator, token);
        } else if (std.mem.startsWith(u8, token, "$(") and std.mem.endsWith(u8, token, ")")) {
            try module_info.libs.append(allocator, token);
            try module_info.cpps.append(allocator, token);
        } else if (std.mem.startsWith(u8, token, "$")) {
            try module_info.libs.append(allocator, token);
            try module_info.cpps.append(allocator, token);
        } else if (std.mem.eql(u8, token, "-u")) {
            try module_info.libs.append(allocator, token);
            skip_next = true;
            skip_type = "libs";
        } else if (std.mem.indexOf(u8, token, ".") == null) {
            // Module name
            module_info.name = token;
            try state.mods.append(allocator, token);
        }
    }

    const module_name = module_info.name orelse @panic("todo");
    // Check if module already configured
    for (state.configured.items) |configured| {
        if (std.mem.eql(u8, configured, module_name)) {
            print("makesetup: '{s}' was handled by previous rule.\n", .{module_name});
            return;
        }
    }
    try state.configured.append(allocator, module_name);

    // Add to appropriate lists based on doconfig
    if (state.doconfig) {
        for (module_info.libs.items) |lib| {
            try state.libs.append(allocator, lib);
        }
        try state.built.append(allocator, module_name);
    } else {
        try state.built.append(allocator, module_name);
        try state.built_shared.append(allocator, module_name);
    }

    if (state.noobjects) return;

    // Process source files and generate rules
    for (module_info.srcs.items) |src| {
        var obj: []const u8 = undefined;
        var cc: []const u8 = undefined;

        if (std.mem.endsWith(u8, src, ".c")) {
            obj = try std.fmt.allocPrint(allocator, "{s}.o", .{basename(src, ".c")});
            cc = "$(CC)";
        } else if (std.mem.endsWith(u8, src, ".cc") or
            std.mem.endsWith(u8, src, ".c++") or
            std.mem.endsWith(u8, src, ".C") or
            std.mem.endsWith(u8, src, ".cxx") or
            std.mem.endsWith(u8, src, ".cpp"))
        {
            obj = try std.fmt.allocPrint(allocator, "{s}.o", .{basename(src, if (std.mem.endsWith(u8, src, ".cc")) ".cc" else if (std.mem.endsWith(u8, src, ".c++")) ".c++" else if (std.mem.endsWith(u8, src, ".C")) ".C" else if (std.mem.endsWith(u8, src, ".cxx")) ".cxx" else ".cpp")});
            cc = "$(CXX)";
        } else if (std.mem.endsWith(u8, src, ".m")) {
            obj = try std.fmt.allocPrint(allocator, "{s}.o", .{basename(src, ".m")});
            cc = "$(CC)";
        } else {
            continue;
        }

        // Adjust paths
        const obj_path = if (std.mem.indexOf(u8, src, "/") != null)
            try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ srcdir, dirname(src), obj })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ srcdir, obj });

        try module_info.objs.append(allocator, obj_path);

        // const src_path = if (std.mem.startsWith(u8, src, "/") or
        //     std.mem.startsWith(u8, src, "$") or
        //     std.mem.eql(u8, src, "glmodule.c"))
        //     src
        // else
        //     try std.fmt.allocPrint(allocator, "$(srcdir)/{s}/{s}", .{ srcdir, src });

        // Generate compilation rule
        const mods_upper = try std.ascii.allocUpperString(allocator, module_name);
        defer allocator.free(mods_upper);

        const cpp_flags = try std.mem.join(allocator, " ", module_info.cpps.items);
        defer allocator.free(cpp_flags);

        // const rule = if (state.doconfig)
        //     try std.fmt.allocPrint(allocator, "{s}: {s} $(MODULE_{s}_DEPS) $(MODULE_DEPS_STATIC) $(PYTHON_HEADERS); {s} {s} $(PY_BUILTIN_MODULE_CFLAGS) -c {s} -o {s}\n", .{ obj_path, src_path, mods_upper, cc, cpp_flags, src_path, obj_path })
        // else
        //     try std.fmt.allocPrint(allocator, "{s}: {s} $(MODULE_{s}_DEPS) $(MODULE_DEPS_SHARED) $(PYTHON_HEADERS); {s} {s} $(PY_STDMODULE_CFLAGS) $(CCSHARED) -c {s} -o {s}\n", .{ obj_path, src_path, mods_upper, cc, cpp_flags, src_path, obj_path });

        // try rules_file.writeAll(rule);
    }

    if (state.doconfig) {
        for (module_info.objs.items) |obj| {
            try state.objs.append(allocator, obj);
        }
    }

    // Generate shared library rule
    if (!state.doconfig) {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}$(EXT_SUFFIX)", .{ srcdir, module_name });
        try state.sharedmods.append(allocator, file_path);

        const mods_upper = try std.ascii.allocUpperString(allocator, module_name);
        defer allocator.free(mods_upper);

        const objs_str = try std.mem.join(allocator, " ", module_info.objs.items);
        defer allocator.free(objs_str);

        const libs_str = try std.mem.join(allocator, " ", module_info.libs.items);
        defer allocator.free(libs_str);

        // const rule = try std.fmt.allocPrint(allocator, "{s}: {s} $(MODULE_{s}_LDEPS); $(BLDSHARED) {s} {s} $(LIBPYTHON) -o {s}\n", .{ file_path, objs_str, mods_upper, objs_str, libs_str, file_path });

        // try rules_file.writeAll(rule);
    }
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // no need to free
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    // no need to free

    const cmdline: Cmdline = blk: {
        var maybe_srcdir: ?[]const u8 = null;
        var noobjects: bool = false;
        const doconfig: bool = true;
        var setup_files: std.ArrayListUnmanaged([]const u8) = .{};

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (false) {
                //
            } else if (std.mem.eql(u8, arg, "--source-dir")) {
                i += 1;
                if (i >= args.len) errExit("missing argument for cmdline option '--source-dir'", .{});
                maybe_srcdir = args[i];
            } else if (std.mem.eql(u8, arg, "-n")) {
                noobjects = true;
            } else if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                break;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                try usage();
            } else {
                setup_files.append(arena, arg) catch |e| oom(e);
            }
        }

        while (i < args.len) : (i += 1) {
            setup_files.append(arena, args[i]) catch |e| oom(e);
        }
        if (setup_files.items.len == 0) setup_files.append(arena, "Setup") catch |e| oom(e);
        break :blk .{
            .srcdir = maybe_srcdir orelse errExit("missing require cmline option '-s SOURCE_DIR'", .{}),
            .noobjects = noobjects,
            .doconfig = doconfig,
            .setup_files = setup_files.toOwnedSlice(arena) catch |e| oom(e),
        };
    };

    var state: BuildState = .{
        .noobjects = cmdline.noobjects,
        .doconfig = cmdline.doconfig,
    };
    defer state.deinit(arena);

    // var rules_file = try std.fs.cwd().createFile("@rules.tmp", .{});
    // defer {
    //     rules_file.close();
    //     std.fs.cwd().deleteFile("@rules.tmp") catch {};
    // }
    // try rules_file.writeAll("\n# Rules appended by makesetup\n");

    for (cmdline.setup_files) |setup_file_path| {
        const content = blk: {
            const file = std.fs.cwd().openFile(setup_file_path, .{}) catch |e| std.debug.panic(
                "open setup file file '{s}' failed with {s}",
                .{ setup_file_path, @errorName(e) },
            );
            defer file.close();
            break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
        };
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: can we free this?
        defer arena.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const stripped = try stripComments(arena, line);
            defer arena.free(stripped);
            if (isEmptyLine(stripped)) continue;
            try processLine(arena, stripped, cmdline.srcdir, &state);
        }
    }

    // Read rules content
    // try rules_file.sync();
    //     const file = std.fs.cwd().openFile(path, .{}) catch |e| std.debug.panic(
    //         "open file '{s}' failed with {s}",
    //         .{ path, @errorName(e) },
    //     );
    //     defer file.close();
    //     return file.readToEndAlloc(allocator, std.math.maxInt(usize));
    // const rules_content = try readFile(arena, "@rules.tmp");
    // defer arena.free(rules_content);

    const config_in_path = std.fs.path.join(arena, &.{ cmdline.srcdir, "Modules", "config.c.in" }) catch |e| oom(e);
    const config_in = blk: {
        const config_in = std.fs.cwd().openFile(config_in_path, .{}) catch |e| std.debug.panic(
            "open file '{s}' failed with {s}",
            .{ config_in_path, @errorName(e) },
        );
        defer config_in.close();
        break :blk try config_in.readToEndAlloc(arena, std.math.maxInt(usize));
    };
    // no need to free

    var out_file = try std.fs.cwd().createFile("config.c", .{});
    defer out_file.close();
    var bw = std.io.bufferedWriter(out_file.writer());
    const writer = bw.writer();

    try writer.print("/* Generated automatically from {s} by makesetup. */\n", .{config_in_path});
    var lines = std.mem.splitScalar(u8, config_in, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "MARKER 1")) |_| {
            for (state.mods.items) |mod| {
                try writer.print("extern PyObject* PyInit_{s}(void);\n", .{mod});
            }
        } else if (std.mem.indexOf(u8, line, "MARKER 2")) |_| {
            for (state.mods.items) |mod| {
                try writer.print("    {{\"{s}\", PyInit_{s}}},\n", .{ mod, mod });
            }
        }
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    try bw.flush();
}

fn oom(e: error{OutOfMemory}) noreturn {
    errExit("{s}", .{@errorName(e)});
}
fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const print = std.debug.print;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
