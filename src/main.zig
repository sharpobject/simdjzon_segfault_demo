const std = @import("std");
const dom = @import("dom.zig");

pub fn main() !void {
    @setEvalBranchQuota(1_000_000);
    const arr: dom.Array = undefined;
    _ = arr.at_pointer("hello");
}

