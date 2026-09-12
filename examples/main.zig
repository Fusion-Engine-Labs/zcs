const std = @import("std");
const zcs = @import("zcs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

pub fn main() !void {
    var world = zcs.World.init(std.heap.page_allocator);
    defer world.deinit();

    _ = try world.registerType(Position, .{ .schema_hash = 1 });
    _ = try world.registerType(Velocity, .{ .schema_hash = 2 });

    const entity = try world.spawnWith(.{
        Position{ .x = 0, .y = 0 },
        Velocity{ .x = 1, .y = 2 },
    });

    var commands = zcs.CommandBuffer.init(&world);
    defer commands.deinit();
    try zcs.Schedule.run(&world, &commands, .{ .delta_time = 1.0 }, .{
        .update = &.{movementSystem},
    });

    const position = world.getComponent(entity, Position).?;
    std.debug.print("position: ({d}, {d})\n", .{ position.x, position.y });
}

fn movementSystem(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const dt = world.getResource(zcs.DeltaTime).seconds;
    var query = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    while (query.nextChunk()) |chunk| {
        for (chunk.write(Position), chunk.read(Velocity)) |*position, velocity| {
            position.x += velocity.x * dt;
            position.y += velocity.y * dt;
        }
    }
}
