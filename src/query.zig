const std = @import("std");
const EntityID = @import("entity.zig").EntityID;
const World = @import("world.zig").World;
const Archetype = @import("archetype.zig").Archetype;
const ComponentId = @import("registry.zig").ComponentId;

pub const QuerySpec = struct {
    read: []const type = &.{},
    write: []const type = &.{},
    with: []const type = &.{},
    without: []const type = &.{},
};

pub fn QueryIterator(comptime spec: QuerySpec) type {
    const required_len = spec.read.len + spec.write.len + spec.with.len;
    return struct {
        const Self = @This();
        world: *World,
        required: [required_len]ComponentId,
        excluded: [spec.without.len]ComponentId,
        columns: [required_len]?Archetype.Column = .{null} ** required_len,
        tick_indices: [required_len]?usize = .{null} ** required_len,
        arch_index: usize = 0,
        chunk_index: usize = 0,
        row_view: ?View = null,
        row_index: usize = 0,

        pub fn init(world: *World) Self {
            var self: Self = undefined;
            self.world = world;

            comptime var n = 0;
            inline for (spec.read) |T| {
                self.required[n] = world.typeId(T);
                n += 1;
            }

            inline for (spec.write) |T| {
                self.required[n] = world.typeId(T);
                n += 1;
            }

            inline for (spec.with) |T| {
                self.required[n] = world.typeId(T);
                n += 1;
            }

            inline for (spec.without, 0..) |T, i| {
                self.excluded[i] = world.typeId(T);
            }

            self.arch_index = 0;
            self.chunk_index = 0;
            self.columns = .{null} ** required_len;
            self.tick_indices = .{null} ** required_len;
            self.row_view = null;
            self.row_index = 0;
            return self;
        }
        fn matches(self: *const Self, arch: *const Archetype) bool {
            for (self.required) |id| {
                if (!arch.has(id)) {
                    return false;
                }
            }
            for (self.excluded) |id| {
                if (arch.has(id)) {
                    return false;
                }
            }
            return true;
        }
        pub const View = struct {
            iterator: *Self,
            archetype: *Archetype,
            chunk_index: usize,
            pub fn len(self: View) usize {
                return self.archetype.chunks.items[self.chunk_index].count;
            }
            pub fn entities(self: View) []const EntityID {
                return Archetype.entityColumn(self.archetype.chunks.items[self.chunk_index]);
            }
            pub fn write(self: View, comptime T: type) []T {
                comptime ensureWrite(T);
                const index = comptime requiredIndex(T);
                self.iterator.world.stampAt(self.archetype, @intCast(self.chunk_index), self.iterator.tick_indices[index].?);
                return self.slice(T);
            }
            pub fn read(self: View, comptime T: type) []const T {
                comptime ensureRead(T);
                return self.sliceConst(T);
            }
            pub fn slice(self: View, comptime T: type) []T {
                const chunk = self.archetype.chunks.items[self.chunk_index];
                if (self.iterator.columns[comptime requiredIndex(T)]) |col| {
                    const ptr: [*]T = @ptrCast(@alignCast(chunk.data[col.offset..].ptr));
                    return ptr[0..self.len()];
                }
                // Tags are represented only in the archetype mask. A ZST
                // slice still needs a valid aligned pointer, but no storage.
                const ptr: [*]T = @ptrCast(@alignCast(chunk.data[0..].ptr));
                return ptr[0..self.len()];
            }
            pub fn sliceConst(self: View, comptime T: type) []const T {
                return self.slice(T);
            }
            pub fn changedSince(self: View, comptime T: type, since: u64) bool {
                const index = self.iterator.tick_indices[comptime requiredIndex(T)] orelse return false;
                return self.archetype.change_ticks.items[self.chunk_index][index] >= since;
            }
            pub fn changeTick(self: View, comptime T: type) u64 {
                const index = self.iterator.tick_indices[comptime requiredIndex(T)] orelse return 0;
                return self.archetype.change_ticks.items[self.chunk_index][index];
            }
        };
        pub fn nextChunk(self: *Self) ?View {
            while (self.arch_index < self.world.archetypes.items.len) {
                const arch = self.world.archetypes.items[self.arch_index];
                if (!self.matches(arch)) {
                    self.arch_index += 1;
                    self.chunk_index = 0;
                    continue;
                }
                if (self.chunk_index == 0) self.prepareColumns(arch);
                if (self.chunk_index < arch.chunks.items.len) {
                    const index = self.chunk_index;
                    self.chunk_index += 1;
                    if (arch.chunks.items[index].count > 0) {
                        return .{ .iterator = self, .archetype = arch, .chunk_index = index };
                    }
                    continue;
                }
                self.arch_index += 1;
                self.chunk_index = 0;
            }
            return null;
        }
        fn prepareColumns(self: *Self, arch: *const Archetype) void {
            for (self.required, 0..) |id, i| {
                self.columns[i] = arch.column(id);
                self.tick_indices[i] = arch.tickIndex(id);
            }
        }
        pub fn next(self: *Self) ?View {
            return self.nextChunk();
        }

        pub const Row = struct {
            view: View,
            index: usize,

            pub fn entity(self: Row) EntityID {
                return self.view.entities()[self.index];
            }

            pub fn write(self: Row, comptime T: type) *T {
                return &self.view.write(T)[self.index];
            }

            pub fn read(self: Row, comptime T: type) *const T {
                return &self.view.read(T)[self.index];
            }

            pub fn changedSince(self: Row, comptime T: type, since: u64) bool {
                return self.view.changedSince(T, since);
            }
        };

        pub fn each(self: *Self) ?Row {
            while (true) {
                if (self.row_view) |view| {
                    if (self.row_index < view.len()) {
                        const index = self.row_index;
                        self.row_index += 1;
                        return .{ .view = view, .index = index };
                    }
                }
                self.row_view = self.nextChunk() orelse return null;
                self.row_index = 0;
            }
        }

        fn ensureWrite(comptime T: type) void {
            inline for (spec.write) |W| {
                if (W == T) {
                    return;
                }
            }
            @compileError(@typeName(T) ++ " is not in the write set");
        }

        fn ensureRead(comptime T: type) void {
            inline for (spec.read) |R| {
                if (R == T) {
                    return;
                }
            }
            inline for (spec.write) |W| {
                if (W == T) {
                    return;
                }
            }
            @compileError(@typeName(T) ++ " is not in the query");
        }

        fn requiredIndex(comptime T: type) comptime_int {
            comptime var index = 0;
            inline for (spec.read) |R| {
                if (R == T) return index;
                index += 1;
            }

            inline for (spec.write) |W| {
                if (W == T) return index;
                index += 1;
            }

            inline for (spec.with) |W| {
                if (W == T) return index;
                index += 1;
            }
            @compileError(@typeName(T) ++ " is not in the query");
        }
    };
}
