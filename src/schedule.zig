const std = @import("std");
const World = @import("world.zig").World;
const CommandBuffer = @import("command_buffer.zig").CommandBuffer;
const resources = @import("resources.zig");

pub const Schedule = struct {
    pub const SystemFn = *const fn (*World, *CommandBuffer) anyerror!void;

    pub const Spec = struct {
        pre_update: []const SystemFn = &.{},
        update: []const SystemFn = &.{},
        post_update: []const SystemFn = &.{},
        render: []const SystemFn = &.{},
    };

    pub const Context = struct {
        delta_time: f32,
    };

    pub fn run(world: *World, commands: *CommandBuffer, context: Context, comptime spec: Spec) !void {
        if (!std.math.isFinite(context.delta_time) or context.delta_time < 0) {
            return error.InvalidDeltaTime;
        }

        if (commands.world != world) {
            return error.CommandBufferWorldMismatch;
        }

        var delta: resources.DeltaTime = .{ .seconds = context.delta_time };
        var resource_scope: resources.Resources.Scope = undefined;
        world.resources.pushScope(resources.DeltaTime, &delta, &resource_scope);
        defer resource_scope.deinit();

        var command_scope: CommandBuffer.Scope = undefined;
        commands.pushScope(&command_scope);
        defer command_scope.deinit();

        world.advanceTick();
        inline for (.{ spec.pre_update, spec.update, spec.post_update, spec.render }) |phase| {
            inline for (phase) |system| {
                try system(world, commands);
            }
            try commands.flush();
        }
    }
};

const testing = std.testing;
const TestValue = struct { value: u32 = 0 };
const TestState = struct {
    first: @import("entity.zig").EntityID,
    second: @import("entity.zig").EntityID,
    pending: @import("entity.zig").EntityID = .nil,
    phase: u32 = 0,
};

fn expectDelta(world: *World, _: *CommandBuffer) !void {
    try testing.expectEqual(@as(f32, 0.125), world.getResource(resources.DeltaTime).seconds);
}

fn removeDeltaAndFail(world: *World, _: *CommandBuffer) !void {
    world.removeResource(resources.DeltaTime);
    try testing.expect(!world.hasResource(resources.DeltaTime));
    try world.setResource(resources.DeltaTime, .{ .seconds = 99 });
    return error.SystemFailed;
}

test "run scopes timing and advances only the ECS change tick" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    try world.setResource(resources.DeltaTime, .{ .seconds = 7 });
    try world.setResource(resources.FrameCount, .{ .value = 42 });
    const delta = world.getResource(resources.DeltaTime);
    const before = world.currentTick();
    try Schedule.run(&world, &commands, .{ .delta_time = 0.125 }, .{ .update = &.{expectDelta} });
    try testing.expectEqual(before + 1, world.currentTick());
    try testing.expectEqual(@as(u64, 42), world.getResource(resources.FrameCount).value);
    try testing.expect(world.getResource(resources.DeltaTime) == delta);
    try testing.expectEqual(@as(f32, 7), delta.seconds);
    try testing.expectError(error.SystemFailed, Schedule.run(&world, &commands, .{ .delta_time = 0.1 }, .{ .update = &.{removeDeltaAndFail} }));
    try testing.expectEqual(@as(f32, 7), delta.seconds);
    try testing.expect(world.getResource(resources.DeltaTime) == delta);
}

test "run restores resource absence and requires no timing allocations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var world = World.init(failing.allocator());
    defer world.deinit();
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    try Schedule.run(&world, &commands, .{ .delta_time = 0.125 }, .{ .update = &.{expectDelta} });
    try testing.expect(!world.hasResource(resources.DeltaTime));
    try testing.expect(!world.hasResource(resources.FrameCount));
    try testing.expectError(error.SystemFailed, Schedule.run(&world, &commands, .{ .delta_time = 0.1 }, .{ .update = &.{removeDeltaAndFail} }));
    try testing.expect(!world.hasResource(resources.DeltaTime));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

fn prePhase(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    try testing.expectEqual(@as(u32, 0), state.phase);
    try commands.addComponent(state.first, TestValue, .{ .value = 1 });
    state.phase = 1;
}
fn updatePhase(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    try testing.expectEqual(@as(u32, 1), state.phase);
    try testing.expectEqual(@as(u32, 1), world.getComponent(state.first, TestValue).?.value);
    try commands.addComponent(state.first, TestValue, .{ .value = 2 });
    state.phase = 2;
}
fn postPhase(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    try testing.expectEqual(@as(u32, 2), state.phase);
    try testing.expectEqual(@as(u32, 2), world.getComponent(state.first, TestValue).?.value);
    try commands.addComponent(state.first, TestValue, .{ .value = 3 });
    state.phase = 3;
}
fn renderPhase(world: *World, _: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    try testing.expectEqual(@as(u32, 3), state.phase);
    try testing.expectEqual(@as(u32, 3), world.getComponent(state.first, TestValue).?.value);
    state.phase = 4;
}

fn testWorld() !World {
    var world = World.init(testing.allocator);
    errdefer world.deinit();
    _ = try world.registerType(TestValue, .{ .schema_hash = 0 });
    const first = try world.spawnWith(.{TestValue{}});
    const second = try world.spawnWith(.{TestValue{}});
    try world.setResource(TestState, .{ .first = first, .second = second });
    return world;
}

test "run preserves phase order and flushes structural commands between phases" {
    var world = try testWorld();
    defer world.deinit();
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    try Schedule.run(&world, &commands, .{ .delta_time = 0.01 }, .{
        .pre_update = &.{prePhase},
        .update = &.{updatePhase},
        .post_update = &.{postPhase},
        .render = &.{renderPhase},
    });
    try testing.expectEqual(@as(u32, 4), world.getResource(TestState).phase);
    try testing.expectEqual(@as(usize, 0), commands.commands.items.len);
}

fn nestedSuccess(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    try testing.expectEqual(@as(f32, 0.01), world.getResource(resources.DeltaTime).seconds);
    try testing.expectEqual(@as(u32, 0), world.getComponent(state.first, TestValue).?.value);
    try commands.addComponent(state.second, TestValue, .{ .value = 22 });
}
fn nestedFailure(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    state.pending = try commands.spawnWith(.{TestValue{ .value = 99 }});
    try commands.addComponent(state.first, TestValue, .{ .value = 99 });
    return error.SystemFailed;
}
fn outerSystem(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    try commands.addComponent(state.first, TestValue, .{ .value = 11 });
    try Schedule.run(world, commands, .{ .delta_time = 0.01 }, .{ .update = &.{nestedSuccess} });
    try testing.expectEqual(@as(f32, 0.1), world.getResource(resources.DeltaTime).seconds);
    try testing.expectEqual(@as(u32, 0), world.getComponent(state.first, TestValue).?.value);
    try testing.expectEqual(@as(u32, 22), world.getComponent(state.second, TestValue).?.value);
    try testing.expectError(error.SystemFailed, Schedule.run(world, commands, .{ .delta_time = 0.02 }, .{ .update = &.{nestedFailure} }));
    try testing.expect(!world.isAlive(state.pending));
    try testing.expectEqual(@as(f32, 0.1), world.getResource(resources.DeltaTime).seconds);
}

test "nested runs restore outer timing and isolate pending commands on success and failure" {
    var world = try testWorld();
    defer world.deinit();
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    const before = world.currentTick();
    try Schedule.run(&world, &commands, .{ .delta_time = 0.1 }, .{ .update = &.{outerSystem} });
    try testing.expectEqual(before + 3, world.currentTick());
    try testing.expectEqual(@as(u32, 11), world.getComponent(world.getResource(TestState).first, TestValue).?.value);
    try testing.expect(!world.hasResource(resources.DeltaTime));
    try testing.expectEqual(@as(usize, 0), commands.commands.items.len);
}

fn failAfterMutation(world: *World, commands: *CommandBuffer) !void {
    const state = world.getResource(TestState);
    world.getComponent(state.first, TestValue).?.value = 5;
    try commands.addComponent(state.first, TestValue, .{ .value = 9 });
    state.pending = try commands.spawnWith(.{TestValue{}});
    return error.SystemFailed;
}

test "system errors discard pending work without undoing direct component writes" {
    var world = try testWorld();
    defer world.deinit();
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    try testing.expectError(error.SystemFailed, Schedule.run(&world, &commands, .{ .delta_time = 0.01 }, .{ .update = &.{failAfterMutation} }));
    const state = world.getResource(TestState);
    try testing.expect(!world.isAlive(state.pending));
    try Schedule.run(&world, &commands, .{ .delta_time = 0.01 }, .{});
    try testing.expectEqual(@as(u32, 5), world.getComponent(state.first, TestValue).?.value);
}

test "invalid timing and foreign command buffers leave world state untouched" {
    var world = World.init(testing.allocator);
    defer world.deinit();
    var other = World.init(testing.allocator);
    defer other.deinit();
    var commands = CommandBuffer.init(&world);
    defer commands.deinit();
    const before = world.currentTick();
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |dt| {
        try testing.expectError(error.InvalidDeltaTime, Schedule.run(&world, &commands, .{ .delta_time = dt }, .{}));
    }
    try testing.expectError(error.CommandBufferWorldMismatch, Schedule.run(&other, &commands, .{ .delta_time = 0 }, .{}));
    try testing.expectEqual(before, world.currentTick());
    try testing.expect(!world.hasResource(resources.DeltaTime));
    try testing.expect(!other.hasResource(resources.DeltaTime));
}
