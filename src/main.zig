const std = @import("std");

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    const allocator = da.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var shouldRefresh = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--refresh")) {
            shouldRefresh = true;
            std.debug.print("Will refresh mirror list!", .{});
        }
    }

    std.debug.print("Updating Zig...\n", .{});

    var iter_dir = try std.fs.openDirAbsolute("/home/kyles", .{ .iterate = true });

    defer iter_dir.close();

    var iter = iter_dir.iterate();

    while (try iter.next()) |entry| {
        if (std.mem.count(u8, entry.name, "beans") > 0) {
            //Found zig. Delete file in home
            std.debug.print("Zig already installed. Uninstalling now...\n", .{});
            const str = try std.fmt.allocPrint(allocator, "/home/kyles/{s}", .{entry.name});
            try std.fs.deleteTreeAbsolute(str);
            allocator.free(str);

            //Delete symlink

            try std.fs.deleteFileAbsolute("/home/kyles/.local/bin/beans");

            break;
        }
    }

    std.debug.print("Zig not installed. Installing new Zig now...\n", .{});

    //Cache mirror files.

    std.fs.cwd().access("mirrors.txt", .{}) catch |err| {
        if (err == std.posix.AccessError.FileNotFound) {
            shouldRefresh = true;
        } else {
            return err;
        }
    };

    if (shouldRefresh) {
        std.debug.print("Refreshing mirror list...\n", .{});
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        var response = std.ArrayList(u8).init(allocator);
        defer response.deinit();
        _ = try client.fetch(.{ .method = .GET, .location = .{ .url = "https://ziglang.org/download/community-mirrors.txt" }, .response_storage = .{ .dynamic = &response } });

        const mirrorFile = try std.fs.cwd().createFile("mirrors.txt", .{});
        defer mirrorFile.close();

        try mirrorFile.writeAll(response.items);
    }

    const mirrorFile = try std.fs.cwd().openFile("mirrors.txt", .{});
    defer mirrorFile.close();

    const mirrorList = try mirrorFile.readToEndAlloc(allocator, 10000);
    //Fetch master version
    std.debug.print("Grabbing master version\n", .{});
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();
    _ = try client.fetch(.{ .method = .GET, .location = .{ .url = "https://ziglang.org/download/index.json" }, .response_storage = .{ .dynamic = &response } });

    const T = struct { master: struct { version: []u8 } };

    const json = try std.json.parseFromSlice(T, allocator, response.items, .{ .ignore_unknown_fields = true });
    defer json.deinit();

    const version = json.value.master.version;

    std.debug.print("{s}\n", .{version});

    std.debug.print("Looping through mirrors.\n", .{});
    var temp = std.ArrayList(u8).init(allocator);
    defer temp.deinit();

    std.debug.print("{s}\n", .{mirrorList});
    //Loop through all mirrors
    for (mirrorList) |value| {
        if (value != '\n') {
            try temp.append(value);
        } else {
            const pubKey = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
            var mirrorRes = std.ArrayList(u8).init(allocator);
            defer mirrorRes.deinit();

            const fileName = try std.fmt.allocPrint(allocator, "zig-x86_64-linux-{s}.tar.xz", .{version});
            defer allocator.free(fileName);

            const url = try std.fmt.allocPrint(allocator, "{s}/{s}?source=github-brakezap-zig-updater", .{ temp.items, fileName });
            defer allocator.free(url);

            std.debug.print("Url: {s}\n", .{url});

            var buffer: [4096]u8 = undefined;

            var req = try client.open(std.http.Method.GET, try std.Uri.parse(url), .{ .server_header_buffer = &buffer });
            defer req.deinit();

            try req.send();
            try req.finish();
            try req.wait();

            if (req.response.status != std.http.Status.ok) {
                temp.clearRetainingCapacity();
                std.debug.print("Status code: {?s}\n", .{req.response.status.phrase()});
                continue;
            }

            const filePath = try std.fmt.allocPrint(allocator, "/home/kyles/{s}", .{fileName});
            defer allocator.free(filePath);

            std.debug.print("File name: {s}\n", .{filePath});

            const tarFile = try std.fs.createFileAbsolute(filePath, .{});
            try req.reader().readAllArrayList(&mirrorRes, 500000000);

            _ = try tarFile.writeAll(mirrorRes.items);
            tarFile.close();
            const miniUrl = try std.fmt.allocPrint(allocator, "{s}/{s}.minisig?source=github-brakezap-zig-updater", .{ temp.items, fileName });
            defer allocator.free(miniUrl);

            var miniSigBytes = std.ArrayList(u8).init(allocator);
            defer miniSigBytes.deinit();

            const miniSigPath = try std.fmt.allocPrint(allocator, "{s}.minisig", .{filePath});
            defer allocator.free(miniSigPath);
            const miniFile = try std.fs.createFileAbsolute(miniSigPath, .{});

            _ = try client.fetch(.{ .method = .GET, .location = .{ .url = miniUrl }, .response_storage = .{ .dynamic = &miniSigBytes } });

            _ = try miniFile.writeAll(miniSigBytes.items);

            miniFile.close();

            var argv = std.ArrayList([]const u8).init(allocator);
            defer argv.deinit();

            try argv.append("minisign");
            try argv.append("-Vm");
            try argv.append(filePath);
            try argv.append("-P");
            try argv.append(pubKey);

            var child = std.process.Child.init(argv.items, allocator);

            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.cwd = "/home/kyles/";

            var stdout: std.ArrayListUnmanaged(u8) = .empty;
            defer stdout.deinit(allocator);
            var stderr: std.ArrayListUnmanaged(u8) = .empty;
            defer stderr.deinit(allocator);

            try child.spawn();
            try child.collectOutput(allocator, &stdout, &stderr, 1024);
            _ = try child.wait();

            std.debug.print("Result: {s}\n", .{stdout.items});
            std.debug.print("Errors: {s}\n", .{stderr.items});

            if (stderr.items.len > 0) {
                std.debug.print("Downloaded Zig binary does not match checksum, potentially corrupt mirror. Please remove mirror from list!\n", .{});

                std.debug.print("Removing corrupted files...\n", .{});

                try std.fs.deleteFileAbsolute(filePath);
                try std.fs.deleteFileAbsolute(miniSigPath);
                return;
            }
            break;
        }
    }

    std.debug.print("Successfully downloaded Zig binaries!", .{});

    //Extract Zig binaries

    //Create symlink in /home/kyles/.local/bin/zig
}
