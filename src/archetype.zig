const std = @import("std");
const EntityID = @import("entity.zig").EntityID;
const chunk_mod = @import("chunk_pool.zig");
const Chunk = chunk_mod.Chunk;
const ChunkPool = chunk_mod.ChunkPool;
const Registry = @import("registry.zig").Registry;
const ComponentId = @import("registry.zig").ComponentId;

/// Runtime-layout archetype.  `mask` may be shorter than a later registry;
/// callers must treat bits beyond its length as absent.
pub const Archetype = struct {
    pub const Column = struct { id: ComponentId, offset: u32, size: usize };
    pub const AppendResult = struct { chunk_idx: u32, row: u16 };

    mask: std.DynamicBitSetUnmanaged,
    chunks: std.ArrayListUnmanaged(*Chunk) = .empty,
    /// Component IDs in the same order as every chunk's compact tick array.
    /// This includes tags: they have no data column but still participate in
    /// change detection.
    change_ids: std.ArrayListUnmanaged(ComponentId) = .empty,
    change_ticks: std.ArrayListUnmanaged([]u64) = .empty,
    columns: std.ArrayListUnmanaged(Column) = .empty,
    component_count: u32 = 0,
    entity_count: u32 = 0,
    capacity: u16,
    pool: *ChunkPool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, registry: *const Registry, mask: std.DynamicBitSetUnmanaged, pool: *ChunkPool) !Archetype {
        var self: Archetype = .{ .mask = mask, .capacity = 1, .pool = pool, .allocator = allocator };
        errdefer self.mask.deinit(allocator);
        errdefer self.change_ids.deinit(allocator);
        errdefer self.columns.deinit(allocator);
        var stride: usize = @sizeOf(EntityID);
        var component_count: u32 = 0;
        var bit: usize = 0;
        while (bit < mask.bit_length) : (bit += 1) {
            if (!mask.isSet(bit)) {
                continue;
            }
            component_count += 1;
            const id: ComponentId = @enumFromInt(@as(u32, @intCast(bit + 1)));
            try self.change_ids.append(allocator, id);
            const desc = registry.desc(id);
            if (desc.size > 0) {
                stride += desc.size;
            }
        }
        self.capacity = @intCast(@min(@max(chunk_mod.chunk_data_size / stride, 1), std.math.maxInt(u16)));
        while (self.capacity > 1 and self.layoutBytes(registry, self.capacity) == null) {
            self.capacity -= 1;
        }
        if (self.layoutBytes(registry, self.capacity) == null) {
            return error.ArchetypeRowTooLarge;
        }

        var offset: usize = @as(usize, self.capacity) * @sizeOf(EntityID);
        bit = 0;
        while (bit < mask.bit_length) : (bit += 1) {
            if (!mask.isSet(bit)) {
                continue;
            }
            const id: ComponentId = @enumFromInt(@as(u32, @intCast(bit + 1)));
            const desc = registry.desc(id);
            if (desc.size == 0) {
                continue;
            }
            offset = std.mem.alignForward(usize, offset, desc.alignment);
            try self.columns.append(allocator, .{ .id = id, .offset = @intCast(offset), .size = desc.size });
            offset += @as(usize, self.capacity) * desc.size;
        }
        self.component_count = component_count;
        return self;
    }

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        for (self.change_ticks.items) |ticks| {
            allocator.free(ticks);
        }
        self.change_ticks.deinit(allocator);
        self.change_ids.deinit(allocator);
        self.chunks.deinit(allocator);
        self.columns.deinit(allocator);
        self.mask.deinit(allocator);
    }

    /// Reset entity storage while retaining the archetype and its layout.
    /// Chunks return to the world's pool, so a subsequent scene can reuse
    /// their allocations without retaining an unbounded per-archetype cache.
    pub fn clear(self: *Archetype) void {
        for (self.chunks.items) |chunk| {
            self.pool.free(chunk);
        }
        self.chunks.clearRetainingCapacity();
        for (self.change_ticks.items) |ticks| {
            self.allocator.free(ticks);
        }
        self.change_ticks.clearRetainingCapacity();
        self.entity_count = 0;
    }

    pub fn has(self: *const Archetype, id: ComponentId) bool {
        const bit = @as(usize, @intFromEnum(id) - 1);
        return bit < self.mask.bit_length and self.mask.isSet(bit);
    }

    /// Check a component set without constructing a temporary DynamicBitSet.
    /// Used after a hash lookup to resolve collisions exactly.
    pub fn hasExactly(self: *const Archetype, ids: []const ComponentId) bool {
        if (self.component_count != ids.len) return false;
        for (ids) |id| {
            if (!self.has(id)) return false;
        }
        return true;
    }

    pub fn column(self: *const Archetype, id: ComponentId) ?Column {
        for (self.columns.items) |entry| {
            if (entry.id == id) {
                return entry;
            }
        }
        return null;
    }

    pub fn tickIndex(self: *const Archetype, id: ComponentId) ?usize {
        for (self.change_ids.items, 0..) |entry, i| {
            if (entry == id) return i;
        }
        return null;
    }

    pub fn appendEntity(self: *Archetype, allocator: std.mem.Allocator, id: EntityID) !AppendResult {
        if (self.chunks.items.len == 0 or self.chunks.items[self.chunks.items.len - 1].count >= self.capacity) {
            try self.chunks.ensureUnusedCapacity(allocator, 1);
            try self.change_ticks.ensureUnusedCapacity(allocator, 1);
            const ticks = try allocator.alloc(u64, self.change_ids.items.len);
            errdefer allocator.free(ticks);
            @memset(ticks, 0);
            const chunk = try self.pool.alloc();
            self.chunks.appendAssumeCapacity(chunk);
            self.change_ticks.appendAssumeCapacity(ticks);
        }
        const chunk_idx: u32 = @intCast(self.chunks.items.len - 1);
        const chunk = self.chunks.items[chunk_idx];
        const row = chunk.count;
        entityColumnMut(chunk)[row] = id;
        chunk.count += 1;
        self.entity_count += 1;
        return .{ .chunk_idx = chunk_idx, .row = row };
    }

    pub fn removeEntity(self: *Archetype, chunk_idx: u32, row: u16) ?EntityID {
        const last_idx: u32 = @intCast(self.chunks.items.len - 1);
        const last = self.chunks.items[last_idx];
        const last_row = last.count - 1;
        const chunk = self.chunks.items[chunk_idx];
        var moved: ?EntityID = null;
        if (chunk_idx != last_idx or row != last_row) {
            moved = entityColumn(last)[last_row];
            entityColumnMut(chunk)[row] = moved.?;
            for (self.columns.items) |col| {
                const dst = cell(chunk, row, col);
                const src = cell(last, last_row, col);
                @memcpy(dst, src);
            }
            if (chunk_idx != last_idx) {
                const dst_ticks = self.change_ticks.items[chunk_idx];
                const src_ticks = self.change_ticks.items[last_idx];
                for (dst_ticks, src_ticks) |*dst, src| {
                    if (src > dst.*) {
                        dst.* = src;
                    }
                }
            }
        }
        last.count -= 1;
        self.entity_count -= 1;
        if (last.count == 0) {
            const removed_chunk = self.chunks.pop().?;
            self.pool.free(removed_chunk);
            const ticks = self.change_ticks.pop().?;
            self.allocator.free(ticks);
        }
        return moved;
    }

    pub fn cell(chunk: *Chunk, row: u16, col: Column) []u8 {
        const start = @as(usize, col.offset) + @as(usize, row) * col.size;
        return chunk.data[start .. start + col.size];
    }
    pub fn columnBytes(self: *const Archetype, chunk: *Chunk, id: ComponentId) ?[]u8 {
        const col = self.column(id) orelse return null;
        return chunk.data[col.offset .. @as(usize, col.offset) + @as(usize, chunk.count) * col.size];
    }
    pub fn entityColumn(chunk: *const Chunk) []const EntityID {
        const ptr: [*]const EntityID = @ptrCast(@alignCast(&chunk.data));
        return ptr[0..chunk.count];
    }
    fn entityColumnMut(chunk: *Chunk) [*]EntityID {
        return @ptrCast(@alignCast(&chunk.data));
    }
    fn layoutBytes(self: *const Archetype, registry: *const Registry, capacity: u16) ?usize {
        var offset = @as(usize, capacity) * @sizeOf(EntityID);
        var bit: usize = 0;
        while (bit < self.mask.bit_length) : (bit += 1) {
            if (!self.mask.isSet(bit)) {
                continue;
            }
            const desc = registry.desc(@enumFromInt(@as(u32, @intCast(bit + 1))));
            if (desc.size == 0) {
                continue;
            }
            offset = std.mem.alignForward(usize, offset, desc.alignment);
            offset += @as(usize, capacity) * desc.size;
        }
        if (offset <= chunk_mod.chunk_data_size) {
            return offset;
        }
        return null;
    }
};
