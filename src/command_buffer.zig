const std = @import("std");
const EntityID = @import("entity.zig").EntityID;
const World = @import("world.zig").World;
const ComponentId = @import("registry.zig").ComponentId;

pub const CommandBuffer = struct {
    const Command = union(enum) {
        spawn: EntityID,
        despawn: EntityID,
        add: struct { entity: EntityID, id: ComponentId, bytes: []const u8 },
        remove: struct { entity: EntityID, id: ComponentId },
    };

    commands: std.ArrayListUnmanaged(Command) = .empty,
    arena: std.heap.ArenaAllocator,
    world: *World,

    pub fn init(world: *World) CommandBuffer {
        return .{ .world = world, .arena = std.heap.ArenaAllocator.init(world.allocator) };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.arena.deinit();
        self.commands.deinit(self.world.allocator);
    }

    pub fn spawn(self: *CommandBuffer) !EntityID {
        const id = try self.world.spawn();
        try self.commands.append(self.world.allocator, .{ .spawn = id });
        return id;
    }

    pub fn despawn(self: *CommandBuffer, id: EntityID) !void {
        try self.commands.append(self.world.allocator, .{ .despawn = id });
    }

    pub fn add(self: *CommandBuffer, entity: EntityID, id: ComponentId, bytes: []const u8) !void {
        const copy = try self.arena.allocator().dupe(u8, bytes);
        try self.commands.append(self.world.allocator, .{ .add = .{ .entity = entity, .id = id, .bytes = copy } });
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
        const id = try self.spawn();
        inline for (std.meta.fields(@TypeOf(values))) |field| {
            try self.addComponent(id, field.type, @field(values, field.name));
        }
        return id;
    }

    pub fn flush(self: *CommandBuffer) !void {
        for (self.commands.items) |command| {
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
        self.commands.clearRetainingCapacity();
        const reset = self.arena.reset(.retain_capacity);
        std.debug.assert(reset);
    }
};
