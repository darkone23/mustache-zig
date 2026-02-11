//! # Writer Compatibility Layer for Zig 0.15.2
//!
//! ## Purpose
//! This module provides compatibility utilities for adapting different writer types to the
//! `std.Io.Writer` interface introduced in Zig 0.15.2. It bridges the gap between the old
//! GenericWriter API and the new Io.Writer fat pointer system.
//!
//! ## Background: Zig 0.13 to 0.15.2 Writer API Changes
//!
//! **Zig 0.13 (Old API):**
//! - Writers were generic types using `anytype`
//! - Each writer type was distinct and handled via generics
//! - Example: `std.ArrayList(u8).Writer`, `std.io.FixedBufferStream.Writer`
//!
//! **Zig 0.15.2 (New API):**
//! - All writers implement `std.Io.Writer` - a fat pointer with vtable
//! - Vtable contains function pointers: drain, flush, rebase, sendFile
//! - Unified interface across all writer types
//! - Example: `std.Io.Writer` handles any writer through dynamic dispatch
//!
//! ## Components
//!
//! 1. **CountingWriter** - Tracks bytes written without storing (for testing)
//! 2. **GenericWriterWrapper** - Adapts old-style GenericWriter to Io.Writer
//! 3. **TestBuffer** - Test helper with ArrayList-backed Io.Writer
//! 4. **BufferWriter** - Production buffer writer using ArrayList
//! 5. **fixedBufferStreamWriter** - Adapts FixedBufferStream to Io.Writer
//!
//! ## Usage Example
//!
//! ```zig
//! // Using the new Io.Writer API
//! var buffer = writer_compat.BufferWriter.init(allocator);
//! defer buffer.deinit();
//!
//! const writer = buffer.allocatingWriter();
//! try mustache.renderText(allocator, template, data, &writer);
//! ```

const std = @import("std");

/// Counting writer for tests - tracks bytes written without storing
///
/// This is useful when you need to know how much would be written
/// without actually allocating storage. Used primarily in test scenarios
/// and for size calculations.
///
/// Usage:
/// ```zig
/// var counter = writer_compat.CountingWriter.init();
/// const writer = counter.writer();
/// try mustache.renderText(allocator, template, data, &writer);
/// std.debug.print("Would write {} bytes\n", .{counter.bytes_written});
/// ```
pub const CountingWriter = struct {
    bytes_written: usize = 0,

    pub fn init() CountingWriter {
        return .{ .bytes_written = 0 };
    }

    /// Returns an Io.Writer interface for this counting writer
    pub fn writer(_: *CountingWriter) std.Io.Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                .flush = flush,
                .rebase = rebase,
                .sendFile = sendFile,
            },
            .buffer = &.{},
            .end = 0,
        };
    }

    fn drain(ctx: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CountingWriter = @ptrCast(@alignCast(ctx));
        var total: usize = 0;
        for (data) |buf| {
            total += buf.len;
        }
        if (splat > 1 and data.len > 0) {
            total += data[data.len - 1].len * (splat - 1);
        }
        self.bytes_written += total;
        return total;
    }

    fn flush(ctx: *std.Io.Writer) std.Io.Writer.Error!void {
        // No-op for counting writer - ctx unused by design
        _ = ctx;
    }

    fn rebase(ctx: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        // No-op for counting writer - parameters unused by design
        _ = ctx;
        _ = preserve;
        _ = capacity;
    }

    fn sendFile(ctx: *std.Io.Writer, file_reader: *std.fs.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        // Not implemented for counting writer
        _ = ctx;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }
};

/// Wrapper to adapt GenericWriter to std.Io.Writer interface
///
/// GenericWriter is the old-style writer type from Zig 0.13 that had a `.write()`
/// method returning the number of bytes written. This wrapper bridges it to the
/// new Io.Writer vtable interface.
///
/// **Migration Note:** This wrapper is primarily for backward compatibility.
/// New code should use `std.Io.Writer` directly.
///
/// Type Parameter:
///   - GenericWriterType: The old-style writer type to wrap
///
/// Usage:
/// ```zig
/// var gw = std.io.fixedBufferStream(&buffer);
/// var wrapper = writer_compat.GenericWriterWrapper(@TypeOf(gw.writer())).init(gw.writer());
/// const writer = wrapper.writer();
/// ```
pub fn GenericWriterWrapper(comptime GenericWriterType: type) type {
    return struct {
        gw: GenericWriterType,

        const Self = @This();

        pub fn init(gw: GenericWriterType) Self {
            return .{ .gw = gw };
        }

        pub fn writer(self: *Self) std.Io.Writer {
            return .{
                .vtable = &vtable,
                .buffer = @ptrCast(self),
                .end = @sizeOf(Self),
            };
        }

        const vtable = std.Io.Writer.VTable{
            .drain = drain,
            .flush = flush,
            .rebase = rebase,
            .sendFile = sendFile,
        };

        fn drain(ctx: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Self = @ptrCast(@alignCast(ctx.buffer));
            var total: usize = 0;
            for (data) |buf| {
                total += self.gw.write(buf) catch return error.WriteFailed;
            }
            if (splat > 1 and data.len > 0) {
                const last = data[data.len - 1];
                var i: usize = 1;
                while (i < splat) : (i += 1) {
                    total += self.gw.write(last) catch return error.WriteFailed;
                }
            }
            return total;
        }

        fn flush(ctx: *std.Io.Writer) std.Io.Writer.Error!void {
            _ = ctx;
        }

        fn rebase(ctx: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
            _ = ctx;
            _ = preserve;
            _ = capacity;
        }

        fn sendFile(ctx: *std.Io.Writer, file_reader: *std.fs.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
            _ = ctx;
            _ = file_reader;
            _ = limit;
            return error.Unimplemented;
        }
    };
}

/// Helper to get a pointer to std.Io.Writer interface
///
/// This function attempts to convert various writer types to a pointer to
/// std.Io.Writer. It handles:
/// - Pointers to Io.Writer (returned as-is)
/// - Const pointers to Io.Writer (cast to mutable)
/// - Types with .writer fields (like Io.Writer.Allocating)
///
/// **Important:** This function cannot handle GenericWriter types directly.
/// Use GenericWriterWrapper for those cases.
///
/// Compile Errors:
/// - If passed an unsupported writer type
/// - If passed a GenericWriter (use GenericWriterWrapper instead)
///
/// Usage:
/// ```zig
/// var writer = std.Io.Writer.Allocating.init(allocator);
/// const any_writer = toAnyWriter(&writer);
/// ```
pub fn toAnyWriter(writer: anytype) *std.Io.Writer {
    const WriterType = @TypeOf(writer);

    // Already a pointer to Io.Writer - return it directly
    if (WriterType == *std.Io.Writer) {
        return writer;
    }

    if (WriterType == *const std.Io.Writer) {
        return @constCast(writer);
    }

    // Handle std.Io.Writer by value - return pointer to it
    if (WriterType == std.Io.Writer) {
        // This is a bit of a hack - we're returning a pointer to a local copy
        // The caller must ensure the writer lives long enough
        @compileError("std.Io.Writer by value not supported - pass a pointer instead");
    }

    // Handle pointer to types with .writer field (like Io.Writer.Allocating)
    const type_info = @typeInfo(WriterType);
    if (type_info == .pointer) {
        const ChildType = type_info.pointer.child;
        if (@hasField(ChildType, "writer") and @hasDecl(ChildType, "init")) {
            return &writer.writer;
        }

        // Handle GenericWriter pointer - wrap it using the GenericWriterWrapper
        if (@hasField(ChildType, "context") and @hasDecl(ChildType, "write")) {
            @compileError("GenericWriter pointer not supported in toAnyWriter - use GenericWriterWrapper directly");
        }
    }

    // Handle GenericWriter by value - wrap it using the GenericWriterWrapper
    if (@hasField(WriterType, "context") and @hasDecl(WriterType, "write")) {
        @compileError("GenericWriter not supported in toAnyWriter - use GenericWriterWrapper directly");
    }

    @compileError("Unsupported writer type: " ++ @typeName(WriterType));
}

/// Test helper that wraps ArrayList and provides a stable Io.Writer interface
///
/// This is specifically designed for use in test cases. It manages an ArrayList
/// and provides methods to get an Io.Writer interface, retrieve the written
/// content, and clean up.
///
/// **Note:** The writer pointer must be refreshed after any operation that might
/// reallocate the ArrayList (like appending more data).
///
/// Usage:
/// ```zig
/// var test_buffer = writer_compat.TestBuffer.init(allocator);
/// defer test_buffer.deinit();
///
/// const writer = test_buffer.getWriter();
/// try mustache.renderText(allocator, template, data, writer);
///
/// try std.testing.expectEqualStrings("expected", test_buffer.items());
/// ```
pub const TestBuffer = struct {
    list: std.array_list.Managed(u8),
    writer: std.Io.Writer,

    pub fn init(allocator: std.mem.Allocator) TestBuffer {
        var list = std.array_list.Managed(u8).init(allocator);
        return .{
            .list = list,
            .writer = createWriter(&list),
        };
    }

    pub fn deinit(self: *TestBuffer) void {
        self.list.deinit();
    }

    /// Returns a pointer to the Io.Writer interface
    ///
    /// **Important:** Call this again after any write operation to ensure
    /// the pointer is valid (the ArrayList may have reallocated).
    pub fn getWriter(self: *TestBuffer) *std.Io.Writer {
        // Update the writer pointer in case list moved
        self.writer = createWriter(&self.list);
        return &self.writer;
    }

    /// Returns the content written so far
    pub fn items(self: *TestBuffer) []const u8 {
        return self.list.items;
    }

    /// Clears the buffer and frees memory
    pub fn clearAndFree(self: *TestBuffer, allocator: std.mem.Allocator) void {
        self.list.clearAndFree(allocator);
    }

    fn createWriter(list: *std.array_list.Managed(u8)) std.Io.Writer {
        return .{
            .vtable = &vtable,
            .buffer = @ptrCast(list),
            .end = @sizeOf(@TypeOf(list.*)),
        };
    }

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
        .flush = flush,
        .rebase = rebase,
        .sendFile = sendFile,
    };

    fn drain(ctx: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const list: *std.array_list.Managed(u8) = @ptrCast(@alignCast(ctx.buffer));
        var total: usize = 0;
        for (data) |buf| {
            list.appendSlice(buf) catch return error.WriteFailed;
            total += buf.len;
        }
        if (splat > 1 and data.len > 0) {
            const last = data[data.len - 1];
            var i: usize = 1;
            while (i < splat) : (i += 1) {
                list.appendSlice(last) catch return error.WriteFailed;
                total += last.len;
            }
        }
        return total;
    }

    fn flush(ctx: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = ctx;
    }

    fn rebase(ctx: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = ctx;
        _ = preserve;
        _ = capacity;
    }

    fn sendFile(ctx: *std.Io.Writer, file_reader: *std.fs.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        _ = ctx;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }
};

/// Wrapper for std.array_list.Managed(u8) to provide std.Io.Writer interface
///
/// This is a production-ready buffer writer that uses ArrayList as the underlying
/// storage. It's more efficient than TestBuffer for production use because it
/// doesn't maintain a separate writer field.
///
/// Usage:
/// ```zig
/// var buffer = writer_compat.BufferWriter.init(allocator);
/// defer buffer.deinit();
///
/// const writer = buffer.allocatingWriter();
/// try mustache.renderText(allocator, template, data, &writer);
///
/// const result = buffer.toOwnedSlice();
/// defer allocator.free(result);
/// ```
pub const BufferWriter = struct {
    list: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) BufferWriter {
        return .{
            .list = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *BufferWriter) void {
        self.list.deinit();
    }

    /// Returns an Allocating writer backed by the ArrayList
    ///
    /// This writer will automatically grow the ArrayList as needed.
    pub fn allocatingWriter(self: *BufferWriter) std.Io.Writer.Allocating {
        return std.Io.Writer.Allocating.fromArrayList(self.list.allocator, &self.list);
    }

    /// Returns the content and resets the buffer
    /// Caller owns the returned memory
    pub fn toOwnedSlice(self: *BufferWriter) []u8 {
        return self.list.toOwnedSlice();
    }

    /// Returns the content with sentinel and resets the buffer
    /// Caller owns the returned memory
    pub fn toOwnedSliceSentinel(self: *BufferWriter, comptime sentinel: u8) [:sentinel]u8 {
        return self.list.toOwnedSliceSentinel(sentinel);
    }
};

/// Creates a std.Io.Writer from a FixedBufferStream
///
/// FixedBufferStream is useful when you want to write to a pre-allocated buffer
/// without dynamic memory allocation. This function adapts it to the Io.Writer
/// interface.
///
/// Usage:
/// ```zig
/// var buffer: [1024]u8 = undefined;
/// var stream = std.io.fixedBufferStream(&buffer);
/// const writer = writer_compat.fixedBufferStreamWriter(&stream);
///
/// try mustache.renderText(allocator, template, data, &writer);
/// const result = stream.getWritten();
/// ```
pub fn fixedBufferStreamWriter(stream: *std.io.FixedBufferStream([]u8)) std.Io.Writer {
    return .{
        .vtable = &fb_vtable,
        .buffer = @ptrCast(stream),
        .end = @sizeOf(@TypeOf(stream.*)),
    };
}

const fb_vtable = std.Io.Writer.VTable{
    .drain = fb_drain,
    .flush = fb_flush,
    .rebase = fb_rebase,
    .sendFile = fb_sendFile,
};

fn fb_drain(ctx: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const stream: *std.io.FixedBufferStream([]u8) = @ptrCast(@alignCast(ctx.buffer));
    var total: usize = 0;
    for (data) |buf| {
        total += stream.write(buf) catch return error.WriteFailed;
    }
    if (splat > 1 and data.len > 0) {
        const last = data[data.len - 1];
        var i: usize = 1;
        while (i < splat) : (i += 1) {
            total += stream.write(last) catch return error.WriteFailed;
        }
    }
    return total;
}

fn fb_flush(ctx: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = ctx;
}

fn fb_rebase(ctx: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
    _ = ctx;
    _ = preserve;
    _ = capacity;
}

fn fb_sendFile(ctx: *std.Io.Writer, file_reader: *std.fs.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
    _ = ctx;
    _ = file_reader;
    _ = limit;
    return error.Unimplemented;
}
