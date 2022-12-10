const std = @import("std");
const dom = @import("simdjzon.zig").dom;

pub fn main() !void {
    @setEvalBranchQuota(1_000_000);
    var argIter = std.process.args();
    var arg = argIter.next() orelse return error.moreArgsPlz;
    var input: [1024]u8 = undefined;
    std.mem.copy(u8, input[0..], arg[0..]);
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    var gpa = gpa_instance.allocator();
    var parser = try dom.Parser.initFixedBuffer(gpa, &input, .{});
    try parser.parse();
    const element = parser.element();
    const channel_str = try (try element.at_pointer("/channel")).get_string();
    _ = channel_str;
}

