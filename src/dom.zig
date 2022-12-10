const std = @import("std");

const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;

pub const Document = struct {
    tape: std.ArrayListUnmanaged(u64),
    string_buf: []u8,
    string_buf_cap: u32,
};

pub const TapeType = enum(u8) {
    ROOT = 'r',
    START_ARRAY = '[',
    END_ARRAY = ']',
    STRING = '"',
    INT64 = 'l',
    UINT64 = 'u',
    DOUBLE = 'd',
    TRUE = 't',
    FALSE = 'f',
    NULL = 'n',
    INVALID = 'i',
    pub inline fn from_u64(x: u64) TapeType {
        return std.meta.intToEnum(TapeType, (x & 0xff00000000000000) >> 56) catch .INVALID;
    }
    pub inline fn encode_value(tt: TapeType, value: u64) u64 {
        assert(value <= std.math.maxInt(u56));
        return @as(u64, @enumToInt(tt)) << 56 | value;
    }
    pub inline fn extract_value(item: u64) u64 {
        return item & value_mask;
    }
    pub const value_mask = 0x00ffffffffffffff;
    pub const count_mask = 0xffffff;
};

pub const Array = struct {
    tape: TapeRef,
    pub fn at(a: Array, idx: usize) ?Element {
        var it = TapeRefIterator.init(a);
        const target_idx = idx + it.tape.idx + idx;
        while (true) {
            if (it.tape.idx == target_idx)
                return Element{ .tape = .{ .doc = it.tape.doc, .idx = it.tape.idx } };
            _ = it.next() orelse break;
        }
        return null;
    }

    pub inline fn at_pointer(arr: Array, _json_pointer: []const u8) !Element {
        if (_json_pointer.len == 0)
            return Element{ .tape = arr.tape }
        else if (_json_pointer[0] != '/')
            return error.INVALID_JSON_POINTER;
        var json_pointer = _json_pointer[1..];
        // - means "the append position" or "the element after the end of the array"
        // We don't support this, because we're returning a real element, not a position.
        if (json_pointer.len == 1 and json_pointer[0] == '-')
            return error.INDEX_OUT_OF_BOUNDS;

        // Read the array index
        var array_index: usize = 0;
        var i: usize = 0;
        while (i < json_pointer.len and json_pointer[i] != '/') : (i += 1) {
            const digit = json_pointer[i] -% '0';
            // Check for non-digit in array index. If it's there, we're trying to get a field in an object
            if (digit > 9) return error.INCORRECT_TYPE;

            array_index = array_index * 10 + digit;
        }
        // 0 followed by other digits is invalid
        if (i > 1 and json_pointer[0] == '0') {
            return error.INVALID_JSON_POINTER;
        } // "JSON pointer array index has other characters after 0"

        // Empty string is invalid; so is a "/" with no digits before it
        if (i == 0)
            return error.INVALID_JSON_POINTER;
        // "Empty string in JSON pointer array index"

        // Get the child
        var child = arr.at(array_index) orelse return error.INVALID_JSON_POINTER;
        // If there is a /, we're not done yet, call recursively.
        if (i < json_pointer.len) {
            child = try child.at_pointer(json_pointer[i..]);
        }
        return child;
    }
};

// TODO rename these
const ElementType = enum(u8) {
    /// Array
    ARRAY = '[',
    /// i64
    INT64 = 'l',
    /// u64: any integer that fits in u64 but *not* i64
    UINT64 = 'u',
    /// double: Any number with a "." or "e" that fits in double.
    DOUBLE = 'd',
    /// []const u8
    STRING = '"',
    /// bool
    BOOL = 't',
    /// null
    NULL = 'n',
};

const Value = union(ElementType) {
    NULL,
    BOOL: bool,
    INT64: i64,
    UINT64: u64,
    DOUBLE: f64,
    STRING: []const u8,
    ARRAY: Array,
};
const TapeRef = struct {
    doc: *const Document,
    idx: usize,

    pub inline fn is(tr: TapeRef, tt: TapeType) bool {
        return tr.tape_ref_type() == tt;
    }
    pub inline fn tape_ref_type(tr: TapeRef) TapeType {
        return TapeType.from_u64(tr.current());
    }
    pub inline fn value(tr: TapeRef) u64 {
        return TapeType.extract_value(tr.current());
    }
    pub inline fn next_value(tr: TapeRef) u64 {
        return TapeType.extract_value(tr.doc.tape.items[tr.idx + 1]);
    }
    pub inline fn after_element(tr: TapeRef) u64 {
        return switch (tr.tape_ref_type()) {
            .START_ARRAY => tr.matching_brace_idx(),
            .UINT64, .INT64, .DOUBLE => tr.idx + 2,
            else => tr.idx + 1,
        };
    }
    pub inline fn matching_brace_idx(tr: TapeRef) u32 {
        const result = @truncate(u32, tr.current());
        // std.log.debug("TapeRef matching_brace_idx() for {} {}", .{ tr.tape_ref_type(), result });
        return result;
    }
    pub inline fn current(tr: TapeRef) u64 {
        // std.log.debug("TapeRef current() idx {} len {}", .{ tr.idx, tr.doc.tape.items.len });
        return tr.doc.tape.items[tr.idx];
    }
    pub inline fn scope_count(tr: TapeRef) u32 {
        return @truncate(u32, (tr.current() >> 32) & TapeType.count_mask);
    }

    pub fn get_string_length(tr: TapeRef) u32 {
        const string_buf_index = tr.value();
        return mem.readIntLittle(u32, (tr.doc.string_buf.ptr + string_buf_index)[0..@sizeOf(u32)]);
    }

    pub fn get_c_str(tr: TapeRef) [*:0]const u8 {
        return @ptrCast([*:0]const u8, tr.doc.string_buf.ptr + tr.value() + @sizeOf(u32));
    }

    pub fn get_as_type(tr: TapeRef, comptime T: type) T {
        comptime assert(@sizeOf(T) == @sizeOf(u64));
        return @bitCast(T, tr.current());
    }

    pub fn get_next_as_type(tr: TapeRef, comptime T: type) T {
        comptime assert(@sizeOf(T) == @sizeOf(u64));
        return @bitCast(T, tr.doc.tape.items[tr.idx + 1]);
    }

    pub fn get_string(tr: TapeRef) []const u8 {
        return tr.get_c_str()[0..tr.get_string_length()];
    }

    pub fn key_equals(tr: TapeRef, string: []const u8) bool {
        // We use the fact that the key length can be computed quickly
        // without access to the string buffer.
        const len = tr.get_string_length();
        if (string.len == len) {
            // TODO: We avoid construction of a temporary string_view instance.
            return mem.eql(u8, string, tr.get_c_str()[0..len]);
        }
        return false;
    }

    pub fn element(tr: TapeRef) Element {
        return .{ .tape = tr.tape };
    }
};

const TapeRefIterator = struct {
    tape: TapeRef,
    end_idx: u64,

    pub fn init(iter: anytype) TapeRefIterator {
        const tape = iter.tape;
        return .{
            .tape = .{ .doc = tape.doc, .idx = tape.idx + 1 },
            .end_idx = tape.after_element() - 1,
        };
    }
    pub fn next(tri: *TapeRefIterator) ?Element {
        tri.tape.idx += 1;
        tri.tape.idx = tri.tape.after_element();
        return if (tri.tape.idx >= tri.end_idx) null else tri.element();
    }

    pub fn element(tri: TapeRefIterator) Element {
        return .{ .tape = tri.tape };
    }
};
pub const Element = struct {
    tape: TapeRef,

    pub inline fn at_pointer(ele: Element, json_pointer: []const u8) !Element {
        return switch (ele.tape.tape_ref_type()) {
            //.START_OBJECT => (try ele.get_object()).at_pointer(json_pointer),
            .START_ARRAY => (try ele.get_array()).at_pointer(json_pointer),
            else => if (json_pointer.len != 0) error.INVALID_JSON_POINTER else ele,
        };
    }

    pub fn at(ele: Element, idx: usize) ?Element {
        return if (ele.get_as_type(.ARRAY)) |a| a.ARRAY.at(idx) else |_| null;
    }

    pub fn get(ele: Element, out: anytype) !void {
        const T = @TypeOf(out);
        const info = @typeInfo(T);
        switch (info) {
            .Pointer => {
                const C = std.meta.Child(T);
                const child_info = @typeInfo(C);
                switch (info.Pointer.size) {
                    .One => {
                        switch (child_info) {
                            .Int => out.* = std.math.cast(C, try if (child_info.Int.signedness == .signed)
                                ele.get_int64()
                            else
                                ele.get_uint64()) orelse return error.Overflow,
                            .Float => out.* = @floatCast(C, try ele.get_double()),
                            .Bool => out.* = try ele.get_bool(),
                            .Optional => out.* = if (ele.is(.NULL))
                                null
                            else blk: {
                                var x: std.meta.Child(C) = undefined;
                                try ele.get(&x);
                                break :blk x;
                            },
                            .Array => try ele.get(@as([]std.meta.Child(C), out)),
                            .Struct => {
                                switch (ele.tape.tape_ref_type()) {
                                    else => return error.INCORRECT_TYPE,
                                }
                            },
                            .Pointer => if (child_info.Pointer.size == .Slice) {
                                out.* = try ele.get_string();
                            } else @compileError("unsupported type: " ++ @typeName(T) ++
                                ". expecting slice"),
                            else => @compileError("unsupported type: " ++ @typeName(T) ++
                                ". int, float, bool or optional type."),
                        }
                    },
                    .Slice => {
                        switch (ele.tape.tape_ref_type()) {
                            .STRING => {
                                const string = ele.get_string() catch unreachable;
                                @memcpy(
                                    @ptrCast([*]u8, out.ptr),
                                    string.ptr,
                                    std.math.min(string.len, out.len * @sizeOf(C)),
                                );
                            },
                            .START_ARRAY => {
                                var arr = ele.get_array() catch unreachable;
                                var it = TapeRefIterator.init(arr);
                                for (out) |*out_ele| {
                                    const arr_ele = Element{ .tape = it.tape };
                                    try arr_ele.get(out_ele);
                                    _ = it.next() orelse break;
                                }
                            },
                            else => return error.INCORRECT_TYPE,
                        }
                    },

                    else => @compileError("unsupported pointer type: " ++ @typeName(T) ++
                        ". expecting slice or single item pointer."),
                }
            },
            else => @compileError("unsupported type: " ++ @typeName(T) ++ ". expecting pointer type."),
        }
    }

    pub fn get_as_type(ele: Element, ele_type: ElementType) !Value {
        return switch (ele_type) {
            .ARRAY => Value{ .ARRAY = try ele.get_array() },
            .INT64 => Value{ .INT64 = try ele.get_int64() },
            .UINT64 => Value{ .UINT64 = try ele.get_uint64() },
            .DOUBLE => Value{ .DOUBLE = try ele.get_double() },
            .STRING => Value{ .STRING = try ele.get_string() },
            .BOOL => Value{ .BOOL = try ele.get_bool() },
            .NULL => if (ele.tape.is(.NULL)) Value{ .NULL = {} } else error.INCORRECT_TYPE,
        };
    }

    pub fn get_array(ele: Element) !Array {
        return (try ele.get_tape_type(.START_ARRAY)).ARRAY;
    }
    pub fn get_int64(ele: Element) !i64 {
        return if (!ele.is(.INT64))
            if (ele.is(.UINT64)) blk: {
                const result = ele.next_tape_value(u64);
                break :blk if (result > std.math.maxInt(i64))
                    error.NUMBER_OUT_OF_RANGE
                else
                    @bitCast(i64, result);
            } else error.INCORRECT_TYPE
        else
            ele.next_tape_value(i64);
    }
    pub fn get_uint64(ele: Element) !u64 {
        return if (!ele.is(.UINT64))
            if (ele.is(.INT64)) blk: {
                const result = ele.next_tape_value(i64);
                break :blk if (result < 0)
                    error.NUMBER_OUT_OF_RANGE
                else
                    @bitCast(u64, result);
            } else error.INCORRECT_TYPE
        else
            ele.next_tape_value(u64);
    }
    pub fn get_double(ele: Element) !f64 {
        return (try ele.get_tape_type(.DOUBLE)).DOUBLE;
    }
    pub fn get_string(ele: Element) ![]const u8 {
        return (try ele.get_tape_type(.STRING)).STRING;
    }
    pub fn get_bool(ele: Element) !bool {
        return switch (ele.tape.tape_ref_type()) {
            .TRUE => true,
            .FALSE => false,
            else => error.INCORRECT_TYPE,
        };
    }

    pub fn get_tape_type(ele: Element, comptime tape_type: TapeType) !Value {
        return switch (ele.tape.tape_ref_type()) {
            tape_type => ele.as_tape_type(tape_type),
            else => error.INCORRECT_TYPE,
        };
    }
    pub fn next_tape_value(ele: Element, comptime T: type) T {
        comptime assert(@sizeOf(T) == @sizeOf(u64));
        return mem.readIntLittle(T, @ptrCast([*]const u8, ele.tape.doc.tape.items.ptr + ele.tape.idx + 1)[0..8]);
    }
    pub fn as_tape_type(ele: Element, comptime tape_type: TapeType) !Value {
        return switch (tape_type) {
            .ROOT,
            .END_ARRAY,
            .INVALID,
            .NULL,
            => error.INCORRECT_TYPE,
            .START_ARRAY => Value{ .ARRAY = .{ .tape = ele.tape } },
            .STRING => Value{ .STRING = ele.tape.get_string() },
            .INT64 => Value{ .INT64 = ele.tape.get_next_as_type(i64) },
            .UINT64 => Value{ .UINT64 = ele.tape.get_next_as_type(u64) },
            .DOUBLE => Value{ .DOUBLE = ele.tape.get_next_as_type(f64) },
            .TRUE => Value{ .BOOL = true },
            .FALSE => Value{ .BOOL = false },
        };
    }

    pub fn is(ele: Element, ele_type: ElementType) bool {
        return switch (ele_type) {
            .ARRAY => ele.tape.is(.START_ARRAY),
            .STRING => ele.tape.is(.STRING),
            .INT64 => ele.tape.is(.INT64),
            .UINT64 => ele.tape.is(.UINT64),
            .DOUBLE => ele.tape.is(.DOUBLE),
            .BOOL => ele.tape.is(.TRUE) or ele.tape.is(.FALSE),
            .NULL => ele.tape.is(.NULL),
        };
    }
};
