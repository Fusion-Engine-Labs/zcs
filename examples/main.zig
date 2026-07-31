const std = @import("std");
const zcs = @import("zcs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

pub fn main() !void {
    var world = zcs.World.init(std.heap.page_allocator);
    defer world.deinit();

    const position_id = try world.registerType(Position, .{ .schema_hash = 1 });
    const velocity_id = try world.registerType(Velocity, .{ .schema_hash = 2 });
    if (position_id == velocity_id) {
        return error.DuplicateComponentId;
    }

    const entity = try world.spawnWith(.{
        Position{ .x = 0, .y = 0 },
        Velocity{ .x = 1, .y = 2 },
    });

    var query = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    while (query.nextChunk()) |chunk| {
        for (chunk.write(Position), chunk.read(Velocity)) |*position, velocity| {
            position.x += velocity.x;
            position.y += velocity.y;
        }
    }

    const position = world.getComponent(entity, Position).?;
    std.debug.print("position: ({d}, {d})\n", .{ position.x, position.y });
}
