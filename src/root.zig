const std = @import("std");
const chunk_pool = @import("chunk_pool.zig");
const entity_mod = @import("entity.zig");
const registry = @import("registry.zig");
const resources = @import("resources.zig");

pub const chunk_data_size = chunk_pool.chunk_data_size;
pub const chunk_align = chunk_pool.chunk_align;

pub const SparseSet = @import("sparse_set.zig").SparseSet;
pub const CommandBuffer = @import("command_buffer.zig").CommandBuffer;
pub const ComponentDesc = registry.ComponentDesc;
pub const ComponentId = registry.ComponentId;
pub const FrameCount = resources.FrameCount;
pub const ChunkPool = chunk_pool.ChunkPool;
pub const DeltaTime = resources.DeltaTime;
pub const FieldDesc = registry.FieldDesc;
pub const FieldType = registry.FieldType;
pub const Resources = resources.Resources;
pub const EntityPool = entity_mod.EntityPool;
pub const Schedule = @import("schedule.zig").Schedule;
pub const Registry = registry.Registry;
pub const QuerySpec = @import("query.zig").QuerySpec;
pub const EntityID = entity_mod.EntityID;
pub const Chunk = chunk_pool.Chunk;
pub const Archetype = @import("archetype.zig").Archetype;
pub const World = @import("world.zig").World;

test "dynamic world preserves payloads across archetype transitions" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const position = try world.registerType(Position, .{ .schema_hash = 1 });
    const velocity = try world.registerType(Velocity, .{ .schema_hash = 2 });
    const entity = try world.spawn();
    const initial = Position{ .x = 1, .y = 2 };
    const movement = Velocity{ .x = 3, .y = 4 };

    try world.add(entity, position, std.mem.asBytes(&initial));
    try world.add(entity, velocity, std.mem.asBytes(&movement));
    try std.testing.expectEqual(@as(f32, 1), world.getComponent(entity, Position).?.x);
    try world.remove(entity, velocity);
    try std.testing.expect(world.has(entity, position));
    try std.testing.expect(!world.has(entity, velocity));
}

test "bundle spawning writes the final archetype directly" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    _ = try world.registerType(Position, .{ .schema_hash = 1 });
    _ = try world.registerType(Velocity, .{ .schema_hash = 2 });

    const entity = try world.spawnWith(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });
    try std.testing.expectEqual(@as(f32, 1), world.getComponent(entity, Position).?.x);
    try std.testing.expectEqual(@as(f32, 4), world.getComponent(entity, Velocity).?.y);

    var query = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    const chunk = query.nextChunk().?;
    try std.testing.expectEqual(@as(usize, 1), chunk.len());
    chunk.write(Position)[0].x += chunk.read(Velocity)[0].x;
    try std.testing.expectEqual(@as(f32, 4), world.getComponent(entity, Position).?.x);
}

test {
    _ = @import("schedule.zig");
    _ = @import("command_buffer.zig");
}
