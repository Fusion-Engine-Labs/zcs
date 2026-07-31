pub const chunk_data_size = @import("chunk_pool.zig").chunk_data_size;
pub const chunk_align = @import("chunk_pool.zig").chunk_align;

pub const SparseSet = @import("sparse_set.zig").SparseSet;
pub const CommandBuffer = @import("command_buffer.zig").CommandBuffer;
pub const ComponentDesc = @import("registry.zig").ComponentDesc;
pub const ComponentId = @import("registry.zig").ComponentId;
pub const FrameCount = @import("resources.zig").FrameCount;
pub const ChunkPool = @import("chunk_pool.zig").ChunkPool;
pub const DeltaTime = @import("resources.zig").DeltaTime;
pub const FieldDesc = @import("registry.zig").FieldDesc;
pub const FieldType = @import("registry.zig").FieldType;
pub const Resources = @import("resources.zig").Resources;
pub const EntityPool = @import("entity.zig").EntityPool;
pub const Schedule = @import("schedule.zig").Schedule;
pub const Registry = @import("registry.zig").Registry;
pub const QuerySpec = @import("query.zig").QuerySpec;
pub const EntityID = @import("entity.zig").EntityID;
pub const Chunk = @import("chunk_pool.zig").Chunk;
pub const World = @import("world.zig").World;

test "dynamic world preserves payloads across archetype transitions" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var world = World.init(@import("std").testing.allocator);
    defer world.deinit();

    const position = try world.registerType(Position, .{ .schema_hash = 1 });
    const velocity = try world.registerType(Velocity, .{ .schema_hash = 2 });
    const entity = try world.spawn();
    const initial = Position{ .x = 1, .y = 2 };
    const movement = Velocity{ .x = 3, .y = 4 };

    try world.add(entity, position, @import("std").mem.asBytes(&initial));
    try world.add(entity, velocity, @import("std").mem.asBytes(&movement));
    try @import("std").testing.expectEqual(@as(f32, 1), world.getComponent(entity, Position).?.x);
    try world.remove(entity, velocity);
    try @import("std").testing.expect(world.has(entity, position));
    try @import("std").testing.expect(!world.has(entity, velocity));
}

test "bundle spawning writes the final archetype directly" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { x: f32, y: f32 };

    var world = World.init(@import("std").testing.allocator);
    defer world.deinit();
    _ = try world.registerType(Position, .{ .schema_hash = 1 });
    _ = try world.registerType(Velocity, .{ .schema_hash = 2 });

    const entity = try world.spawnWith(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .x = 3, .y = 4 },
    });
    try @import("std").testing.expectEqual(@as(f32, 1), world.getComponent(entity, Position).?.x);
    try @import("std").testing.expectEqual(@as(f32, 4), world.getComponent(entity, Velocity).?.y);

    var query = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    const chunk = query.nextChunk().?;
    try @import("std").testing.expectEqual(@as(usize, 1), chunk.len());
    chunk.write(Position)[0].x += chunk.read(Velocity)[0].x;
    try @import("std").testing.expectEqual(@as(f32, 4), world.getComponent(entity, Position).?.x);
}
