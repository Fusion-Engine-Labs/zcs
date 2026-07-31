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

    pub fn tick(world: *World, commands: *CommandBuffer, comptime spec: Spec) !void {
        world.advanceTick();
        inline for (.{ spec.pre_update, spec.update, spec.post_update, spec.render }) |phase| {
            inline for (phase) |system| {
                try system(world, commands);
            }
            try commands.flush();
        }
    }

    pub fn tickDt(world: *World, commands: *CommandBuffer, dt: f32, comptime spec: Spec) !void {
        try world.setResource(resources.DeltaTime, .{ .seconds = dt });
        if (world.getResourceOrNull(resources.FrameCount)) |frame| {
            frame.value += 1;
        } else {
            try world.setResource(resources.FrameCount, .{ .value = 1 });
        }

        try tick(world, commands, spec);
    }
};
