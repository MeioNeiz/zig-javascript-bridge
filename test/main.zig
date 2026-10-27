// Run by test/run.mjs in node: it calls every export starting with "test", then, after
// pending promises settle, every export starting with "check", and fails any that leaves
// a handle unreleased.  A failure panics, which throws into javascript with the message.
const std = @import("std");
const zjb = @import("zjb");

pub const panic = zjb.panic;

const alloc = std.heap.wasm_allocator;

fn expectEqualStrings(expected: []const u8, actual: []const u8) void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.panic("expected \"{s}\", got \"{s}\"", .{ expected, actual });
    }
}

fn expect(ok: bool, comptime what: []const u8) void {
    if (!ok) @panic(what);
}

fn expectNoSpace(result: error{NoSpaceLeft}![]u8) void {
    if (result) |_| @panic("expected NoSpaceLeft") else |_| {}
}

fn unreleasedHandles() callconv(.c) i32 {
    return @intCast(zjb.unreleasedHandleCount());
}

var main_ran = false;
export fn main() void {
    main_ran = true;
}
fn mainRan() callconv(.c) bool {
    return main_ran;
}

const text = "héllo, wörld 🦎";

fn testReadString() callconv(.c) void {
    const s = zjb.string(text);
    defer s.release();

    var buf: [64]u8 = undefined;
    expectEqualStrings(text, s.readString(&buf) catch @panic("no space"));

    var exact: [text.len]u8 = undefined;
    expectEqualStrings(text, s.readString(&exact) catch @panic("no space"));

    var short: [text.len - 1]u8 = undefined;
    expectNoSpace(s.readString(&short));

    var none: [0]u8 = .{};
    expectNoSpace(s.readString(&none));
    expectEqualStrings("", zjb.string("").readString(&none) catch @panic("no space"));
}

fn testReadStringConverts() callconv(.c) void {
    var buf: [32]u8 = undefined;
    const n = zjb.global("Number").call("parseFloat", .{zjb.constString("2.5")}, zjb.Handle);
    defer n.release();
    expectEqualStrings("2.5", n.readString(&buf) catch @panic("no space"));

    // A lone surrogate isn't valid UTF-16; TextEncoder writes U+FFFD for it.
    const lone = zjb.global("String").call("fromCharCode", .{0xD800}, zjb.Handle);
    defer lone.release();
    expectEqualStrings("\u{FFFD}", lone.readString(&buf) catch @panic("no space"));
}

fn testAllocString() callconv(.c) void {
    const s = zjb.string(text);
    defer s.release();
    const copy = s.allocString(alloc) catch @panic("oom");
    defer alloc.free(copy);
    expectEqualStrings(text, copy);

    const empty = zjb.constString("").allocString(alloc) catch @panic("oom");
    defer alloc.free(empty);
    expectEqualStrings("", empty);
}

fn testAllocStringGrowsMemory() callconv(.c) void {
    // Bigger than all of wasm memory at the start, so allocating grows it, which detaches
    // every view made before.
    const s = zjb.constString("abc€").call("repeat", .{1 << 20}, zjb.Handle);
    defer s.release();
    const copy = s.allocString(alloc) catch @panic("oom");
    defer alloc.free(copy);
    expect(copy.len == 6 << 20, "length");
    expectEqualStrings("abc€abc€", copy[0..12]);
    expectEqualStrings("abc€", copy[copy.len - 6 ..]);
}

fn testReadBytes() callconv(.c) void {
    const src = [_]u8{ 1, 2, 3, 250 };
    const view = zjb.u8ArrayView(&src);
    defer view.release();
    // slice() copies, so this is a javascript owned Uint8Array.
    const arr = view.call("slice", .{}, zjb.Handle);
    defer arr.release();

    var buf: [8]u8 = undefined;
    const got = arr.readBytes(&buf) catch @panic("no space");
    expect(std.mem.eql(u8, &src, got), "bytes");

    var short: [3]u8 = .{ 9, 9, 9 };
    expectNoSpace(arr.readBytes(&short));
    expect(std.mem.eql(u8, &.{ 9, 9, 9 }, &short), "short buffer untouched");

    const owned = arr.allocBytes(alloc) catch @panic("oom");
    defer alloc.free(owned);
    expect(std.mem.eql(u8, &src, owned), "alloc bytes");
}

fn testReadBytesOtherSources() callconv(.c) void {
    var buf: [8]u8 = undefined;

    const buffer = zjb.global("ArrayBuffer").new(.{3});
    defer buffer.release();
    expect((buffer.readBytes(&buf) catch @panic("no space")).len == 3, "ArrayBuffer");

    // Typed arrays and DataViews give their bytes, little endian on every browser.
    const words = zjb.global("Uint16Array").new(.{2});
    defer words.release();
    words.indexSet(0, 0x0102);
    words.indexSet(1, 0x0304);
    const got = words.readBytes(&buf) catch @panic("no space");
    expect(std.mem.eql(u8, &.{ 2, 1, 4, 3 }, got), "Uint16Array bytes");

    const dv = zjb.global("DataView").new(.{buffer});
    defer dv.release();
    expect((dv.readBytes(&buf) catch @panic("no space")).len == 3, "DataView");

    const empty = zjb.global("Uint8Array").new(.{0});
    defer empty.release();
    var none: [0]u8 = .{};
    expect((empty.readBytes(&none) catch @panic("no space")).len == 0, "empty");
}

fn add(context: i32, x: i32) callconv(.c) i32 {
    return context + x;
}

fn testBind() callconv(.c) void {
    const bound = zjb.fnHandle("add", &add).bind(.{@as(i32, 40)});
    defer bound.release();
    expect(bound.call("call", .{ zjb.ConstHandle.null, @as(i32, 2) }, i32) == 42, "bound");
}

var resolved_with: [16]u8 = undefined;
var resolved_len: usize = 0;
var resolved_context: i32 = 0;

fn onResolved(context: i32, value: zjb.Handle) callconv(.c) void {
    defer value.release();
    resolved_context = context;
    resolved_len = (value.readString(&resolved_with) catch @panic("no space")).len;
}

fn testPromiseThen() callconv(.c) void {
    const p = zjb.global("Promise").call("resolve", .{zjb.constString("done")}, zjb.Handle);
    defer p.release();
    const callback = zjb.fnHandle("onResolved", &onResolved).bind(.{@as(i32, 7)});
    defer callback.release();
    const chained = p.call("then", .{callback}, zjb.Handle);
    chained.release();
}

fn checkPromiseThen() callconv(.c) void {
    expect(resolved_context == 7, "context");
    expectEqualStrings("done", resolved_with[0..resolved_len]);
}

fn testScope() callconv(.c) void {
    const before = zjb.unreleasedHandleCount();
    var kept: zjb.Handle = .null;
    {
        const s = zjb.scope();
        defer s.end();
        _ = zjb.string("a");
        _ = zjb.global("Object").new(.{});
        kept = zjb.string("kept").kept();
        expect(zjb.unreleasedHandleCount() == before + 3, "made in the scope");
    }
    expect(zjb.unreleasedHandleCount() == before + 1, "scope released all but the kept one");
    expect(zjb.unkeptHandleCount() == 0, "nothing unkept");
    var buf: [8]u8 = undefined;
    expectEqualStrings("kept", kept.readString(&buf) catch @panic("no space"));
    kept.release();
}

fn testScopeKeepsConstHandles() callconv(.c) void {
    {
        const s = zjb.scope();
        defer s.end();
        // First use of this const string and global: made inside the scope.
        _ = zjb.global("Math").call("max", .{ zjb.constString("1"), @as(i32, 0) }, f64);
    }
    var buf: [8]u8 = undefined;
    expectEqualStrings("1", zjb.constString("1").readString(&buf) catch @panic("no space"));
    expect(zjb.global("Math").call("min", .{ @as(i32, 2), @as(i32, 3) }, f64) == 2, "global survived");
}

fn testScopesNest() callconv(.c) void {
    const outer = zjb.scope();
    const a = zjb.string("outer");
    {
        const inner = zjb.scope();
        defer inner.end();
        _ = zjb.string("inner");
    }
    var buf: [8]u8 = undefined;
    expectEqualStrings("outer", a.readString(&buf) catch @panic("no space"));
    outer.end();
}

fn testReleasedKeptHandle() callconv(.c) void {
    const s = zjb.scope();
    defer s.end();
    const h = zjb.string("x").kept();
    h.release();
    expect(zjb.unkeptHandleCount() == 0, "a released kept handle isn't counted");
}

comptime {
    zjb.exportFn("mainRan", &mainRan);
    zjb.exportFn("unreleasedHandles", &unreleasedHandles);
    zjb.exportFn("testReadString", &testReadString);
    zjb.exportFn("testReadStringConverts", &testReadStringConverts);
    zjb.exportFn("testAllocString", &testAllocString);
    zjb.exportFn("testAllocStringGrowsMemory", &testAllocStringGrowsMemory);
    zjb.exportFn("testReadBytes", &testReadBytes);
    zjb.exportFn("testReadBytesOtherSources", &testReadBytesOtherSources);
    zjb.exportFn("testBind", &testBind);
    zjb.exportFn("testPromiseThen", &testPromiseThen);
    zjb.exportFn("checkPromiseThen", &checkPromiseThen);
    zjb.exportFn("testScope", &testScope);
    zjb.exportFn("testScopeKeepsConstHandles", &testScopeKeepsConstHandles);
    zjb.exportFn("testScopesNest", &testScopesNest);
    zjb.exportFn("testReleasedKeptHandle", &testReleasedKeptHandle);
}
