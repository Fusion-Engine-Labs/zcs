const std = @import("std");
const zcs = @import("zcs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const entity_count = 100_000;
const warmup_count = 3;
const iteration_count = 10;

pub fn main(init: std.process.Init) !void {
    var spawn_total: i96 = 0;
    var iterate_total: i96 = 0;

    for (0..warmup_count + iteration_count) |iteration| {
        var world = zcs.World.init(init.gpa);
        defer world.deinit();

        _ = try world.registerType(Position, .{ .schema_hash = 1 });
        _ = try world.registerType(Velocity, .{ .schema_hash = 2 });

        const spawn_start = timestamp(init.io);
        var last_entity = zcs.EntityID.nil;
        for (0..entity_count) |index| {
            const value: f32 = @floatFromInt(index);
            last_entity = try world.spawnWith(.{
                Position{ .x = value, .y = 0 },
                Velocity{ .x = 1, .y = 1 },
            });
        }
        if (!world.isAlive(last_entity)) {
            return error.SpawnFailed;
        }
        const spawn_elapsed = timestamp(init.io) - spawn_start;

        const iterate_start = timestamp(init.io);
        var query = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
        while (query.nextChunk()) |chunk| {
            for (chunk.write(Position), chunk.read(Velocity)) |*position, velocity| {
                position.x += velocity.x;
                position.y += velocity.y;
            }
        }
        const iterate_elapsed = timestamp(init.io) - iterate_start;

        if (iteration >= warmup_count) {
            spawn_total += spawn_elapsed;
            iterate_total += iterate_elapsed;
        }
    }

    const divisor = @as(f64, @floatFromInt(iteration_count * entity_count));
    std.debug.print("spawnWith: {d:.1} ns/entity\n", .{@as(f64, @floatFromInt(spawn_total)) / divisor});
    std.debug.print("chunk update: {d:.1} ns/entity\n", .{@as(f64, @floatFromInt(iterate_total)) / divisor});
}

fn timestamp(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .boot).nanoseconds;
}
