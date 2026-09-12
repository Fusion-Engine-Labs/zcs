const std = @import("std");
const chunk_mod = @import("chunk_pool.zig");
const EntityID = @import("entity.zig").EntityID;

/// Process-local component ordinal.  Zero is deliberately never assigned.
pub const ComponentId = enum(u32) { invalid = 0, _ };

/// A deliberately small description vocabulary.  zcs does not interpret it;
/// it is retained so scene/ABI layers can describe persisted fields.
pub const FieldType = enum {
    bool,
    integer,
    float,
    enum_,
    array,
    struct_,
    pointer,
    @"opaque",
};

pub const FieldDesc = struct {
    name: []const u8,
    type: FieldType,
    offset: usize,
};

pub const ComponentDesc = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
    schema_hash: u64,
    fields: []const FieldDesc = &.{},
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    descs: std.ArrayListUnmanaged(ComponentDesc) = .empty,
    by_name: std.StringHashMapUnmanaged(ComponentId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        for (self.descs.items) |entry| {
            self.freeDesc(entry);
        }
        self.descs.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
    }

    pub fn count(self: *const Registry) usize {
        return self.descs.items.len;
    }

    pub fn register(self: *Registry, input: ComponentDesc) !ComponentId {
        if (input.name.len == 0) {
            return error.EmptyComponentName;
        }

        if (self.by_name.contains(input.name)) {
            return error.DuplicateComponentName;
        }

        if (input.alignment == 0 or !std.math.isPowerOfTwo(input.alignment)) {
            return error.InvalidComponentAlignment;
        }

        if (input.size > 0 and input.alignment > chunk_mod.chunk_align) {
            return error.OverAlignedComponent;
        }

        if (@sizeOf(EntityID) + input.size > chunk_mod.chunk_data_size) {
            return error.ComponentTooLarge;
        }

        if (self.descs.items.len >= std.math.maxInt(u32) - 1) {
            return error.TooManyComponents;
        }

        try self.descs.ensureUnusedCapacity(self.allocator, 1);
        try self.by_name.ensureUnusedCapacity(self.allocator, 1);

        const copied = try self.dupeDesc(input);
        errdefer self.freeDesc(copied);
        const component_id: ComponentId = @enumFromInt(@as(u32, @intCast(self.descs.items.len + 1)));
        self.descs.appendAssumeCapacity(copied);
        self.by_name.putAssumeCapacityNoClobber(copied.name, component_id);
        return component_id;
    }

    pub fn id(self: *const Registry, name: []const u8) ?ComponentId {
        return self.by_name.get(name);
    }

    pub fn desc(self: *const Registry, component: ComponentId) *const ComponentDesc {
        const ordinal = @intFromEnum(component);
        std.debug.assert(ordinal != 0 and ordinal <= self.descs.items.len);
        return &self.descs.items[ordinal - 1];
    }

    fn dupeDesc(self: *Registry, input: ComponentDesc) !ComponentDesc {
        const name = try self.allocator.dupe(u8, input.name);
        errdefer self.allocator.free(name);

        const fields = try self.allocator.alloc(FieldDesc, input.fields.len);
        errdefer self.allocator.free(fields);
        var initialized: usize = 0;
        errdefer for (fields[0..initialized]) |field| self.allocator.free(field.name);

        for (input.fields, 0..) |field, i| {
            fields[i] = .{ .name = try self.allocator.dupe(u8, field.name), .type = field.type, .offset = field.offset };
            initialized += 1;
        }

        return .{ .name = name, .size = input.size, .alignment = input.alignment, .schema_hash = input.schema_hash, .fields = fields };
    }

    fn freeDesc(self: *Registry, entry: ComponentDesc) void {
        self.allocator.free(entry.name);
        for (entry.fields) |field| {
            self.allocator.free(field.name);
        }
        self.allocator.free(entry.fields);
    }
};

test "registry deep copies descriptors" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var name = [_]u8{ 'T', 'e', 's', 't' };
    var field_name = [_]u8{'x'};
    const id = try registry.register(.{ .name = &name, .size = 4, .alignment = 4, .schema_hash = 7, .fields = &.{.{ .name = &field_name, .type = .float, .offset = 0 }} });
    name[0] = 'X';
    field_name[0] = 'y';
    try std.testing.expectEqualStrings("Test", registry.desc(id).name);
    try std.testing.expectEqualStrings("x", registry.desc(id).fields[0].name);
}

fn testRegisterFailure(allocator: std.mem.Allocator) !void {
    var registry = Registry.init(allocator);
    defer registry.deinit();
    _ = registry.register(.{
        .name = "Test",
        .size = 8,
        .alignment = 4,
        .schema_hash = 7,
        .fields = &.{
            .{ .name = "x", .type = .float, .offset = 0 },
            .{ .name = "y", .type = .float, .offset = 4 },
        },
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), registry.count());
        try std.testing.expect(registry.id("Test") == null);
        return err;
    };
}

test "registry insertion is failure-safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testRegisterFailure, .{});
}
