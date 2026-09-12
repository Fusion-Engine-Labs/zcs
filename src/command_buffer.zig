const std = @import("std");
const EntityID = @import("entity.zig").EntityID;
const World = @import("world.zig").World;
const ComponentId = @import("registry.zig").ComponentId;

pub const CommandBuffer = struct {
    pub const Scope = struct {
        buffer: *CommandBuffer,
        previous: ?*Scope,
        start: usize,

        pub fn deinit(self: *Scope) void {
            std.debug.assert(self.buffer.scope_head == self);
            self.buffer.discard();
            self.buffer.scope_head = self.previous;
            self.* = undefined;
        }
    };

    const Command = union(enum) {
        spawn: EntityID,
        despawn: EntityID,
        add: struct { entity: EntityID, id: ComponentId, bytes: []const u8 },
        remove: struct { entity: EntityID, id: ComponentId },
    };

    commands: std.ArrayListUnmanaged(Command) = .empty,
    arena: std.heap.ArenaAllocator,
    world: *World,
    scope_head: ?*Scope = null,

    pub fn init(world: *World) CommandBuffer {
        return .{ .world = world, .arena = std.heap.ArenaAllocator.init(world.allocator) };
    }

    pub fn deinit(self: *CommandBuffer) void {
        std.debug.assert(self.scope_head == null);
        self.discard();
        self.arena.deinit();
        self.commands.deinit(self.world.allocator);
    }

    pub fn spawn(self: *CommandBuffer) !EntityID {
        const id = try self.world.spawn();
        errdefer self.world.despawn(id);
        try self.commands.append(self.world.allocator, .{ .spawn = id });
        return id;
    }

    pub fn despawn(self: *CommandBuffer, id: EntityID) !void {
        try self.commands.append(self.world.allocator, .{ .despawn = id });
    }

    pub fn add(self: *CommandBuffer, entity: EntityID, id: ComponentId, bytes: []const u8) !void {
        try self.commands.ensureUnusedCapacity(self.world.allocator, 1);
        const copy = try self.arena.allocator().dupe(u8, bytes);
        self.commands.appendAssumeCapacity(.{ .add = .{ .entity = entity, .id = id, .bytes = copy } });
    }

    pub fn remove(self: *CommandBuffer, entity: EntityID, id: ComponentId) !void {
        try self.commands.append(self.world.allocator, .{ .remove = .{ .entity = entity, .id = id } });
    }

    pub fn addComponent(self: *CommandBuffer, entity: EntityID, comptime T: type, value: T) !void {
        try self.add(entity, self.world.typeId(T), std.mem.asBytes(&value));
    }

    pub fn removeComponent(self: *CommandBuffer, entity: EntityID, comptime T: type) !void {
        try self.remove(entity, self.world.typeId(T));
    }

    pub fn spawnWith(self: *CommandBuffer, values: anytype) !EntityID {
        const start = self.commands.items.len;
        errdefer self.discardFrom(start);
        const id = try self.spawn();
        inline for (std.meta.fields(@TypeOf(values))) |field| {
            try self.addComponent(id, field.type, @field(values, field.name));
        }
        return id;
    }

    pub fn flush(self: *CommandBuffer) !void {
        const start = self.scopeStart();
        var applied = start;
        defer self.truncate(start);
        // Applied commands stay committed. Cancel only the unprocessed suffix;
        // it must never be replayed after a failed flush.
        errdefer self.discardFrom(applied);
        while (applied < self.commands.items.len) : (applied += 1) {
            const command = self.commands.items[applied];
            switch (command) {
                .spawn => {},
                .despawn => |id| {
                    self.world.despawn(id);
                },
                .add => |op| {
                    try self.world.add(op.entity, op.id, op.bytes);
                },
                .remove => |op| {
                    try self.world.remove(op.entity, op.id);
                },
            }
        }
    }

    pub fn discard(self: *CommandBuffer) void {
        self.discardFrom(self.scopeStart());
    }

    pub fn pushScope(self: *CommandBuffer, scope: *Scope) void {
        scope.* = .{ .buffer = self, .previous = self.scope_head, .start = if (self.scope_head == null) 0 else self.commands.items.len };
        self.scope_head = scope;
    }

    fn scopeStart(self: *const CommandBuffer) usize {
        return if (self.scope_head) |scope| scope.start else 0;
    }

    fn discardFrom(self: *CommandBuffer, start: usize) void {
        for (self.commands.items[start..]) |command| {
            switch (command) {
                .spawn => |id| self.world.despawn(id),
                else => {},
            }
        }
        self.truncate(start);
    }

    fn truncate(self: *CommandBuffer, start: usize) void {
        self.commands.shrinkRetainingCapacity(start);
        if (start == 0) {
            _ = self.arena.reset(.retain_capacity);
        }
    }
};

const testing = std.testing;
const TestValue = struct { value: u32 = 0 };

test "discard cancels queued spawns and preserves existing entities" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.registerType(TestValue, .{ .schema_hash = 0 });
    const existing = try world.spawnWith(.{TestValue{ .value = 7 }});
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    const pending = try commands.spawnWith(.{TestValue{ .value = 9 }});
    try commands.despawn(existing);
    commands.discard();
    try testing.expect(!world.isAlive(pending));
    try testing.expect(world.isAlive(existing));
    try commands.flush();
    try testing.expectEqual(@as(u32, 7), world.getComponent(existing, TestValue).?.value);
}

test "failed flush preserves applied commands and discards the remaining suffix" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    const component = try world.registerType(TestValue, .{ .schema_hash = 0 });
    const existing = try world.spawnWith(.{TestValue{}});
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    try commands.addComponent(existing, TestValue, .{ .value = 42 });
    try commands.add(existing, component, &.{}); // Invalid payload at flush time.
    try commands.despawn(existing);
    const pending = try commands.spawn();
    try testing.expectError(error.InvalidComponentPayloadSize, commands.flush());
    try testing.expect(!world.isAlive(pending));
    try testing.expectEqual(@as(u32, 42), world.getComponent(existing, TestValue).?.value);
    try testing.expectEqual(@as(usize, 0), commands.commands.items.len);
    try commands.addComponent(existing, TestValue, .{ .value = 43 });
    try commands.flush();
    try testing.expectEqual(@as(u32, 43), world.getComponent(existing, TestValue).?.value);
}

fn testSpawnFailure(allocator: std.mem.Allocator) !void {
    // Restrict failure injection to command allocation: entity allocation has
    // its own tests and must not obscure rollback of command-owned spawns.
    var world = World.init(testing.allocator);
    defer world.deinit();
    _ = try world.registerType(TestValue, .{ .schema_hash = 0 });
    var commands = CommandBuffer.init(&world);
    commands.commands = .empty;
    commands.arena = std.heap.ArenaAllocator.init(allocator);
    defer commands.deinit();
    _ = commands.spawnWith(.{TestValue{ .value = 1 }}) catch |err| {
        try testing.expectEqual(@as(u32, 0), world.entity_pool.alive_count);
        try testing.expectEqual(@as(usize, 0), commands.commands.items.len);
        return err;
    };
    commands.discard();
    try testing.expectEqual(@as(u32, 0), world.entity_pool.alive_count);
}

test "spawnWith rolls back its entity and queued commands on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, testSpawnFailure, .{});
}

test "deinit discards an abandoned deferred spawn" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var commands = CommandBuffer.init(&world);
    const pending = try commands.spawn();
    commands.deinit();
    try testing.expect(!world.isAlive(pending));
}

test "spawn releases its entity when queuing the spawn command fails" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    try world.preWarm(8, 0);
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    world.allocator = failing.allocator();
    defer world.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, commands.spawn());
    try testing.expectEqual(@as(u32, 0), world.entity_pool.alive_count);
    try testing.expectEqual(@as(usize, 0), commands.commands.items.len);
}
