const std = @import("std");
const EntityID = @import("entity.zig").EntityID;
const EntityPool = @import("entity.zig").EntityPool;
const ChunkPool = @import("chunk_pool.zig").ChunkPool;
const Archetype = @import("archetype.zig").Archetype;
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const ComponentId = registry_mod.ComponentId;
const Resources = @import("resources.zig").Resources;
const query_mod = @import("query.zig");

/// The one zcs storage implementation.  Component descriptors are registered
/// at runtime; typed methods below are only checked views over this byte API.
pub const World = struct {
    const Self = @This();
    const TransitionKey = struct { source: *Archetype, component: ComponentId, adding: bool };
    pub const EntityLocation = struct { archetype: ?*Archetype = null, chunk_idx: u32 = 0, row: u16 = 0 };
    pub const RawComponent = struct { id: ComponentId, data: []const u8 };
    pub const Observers = struct {
        ctx: *anyopaque = undefined,
        on_spawn: ?*const fn (*anyopaque, EntityID) void = null,
        on_despawn: ?*const fn (*anyopaque, EntityID) void = null,
        on_add: ?*const fn (*anyopaque, EntityID, ComponentId) void = null,
        on_remove: ?*const fn (*anyopaque, EntityID, ComponentId) void = null,
    };

    allocator: std.mem.Allocator,
    registry: Registry,
    type_ids: std.StringHashMapUnmanaged(ComponentId) = .empty,
    entity_pool: EntityPool,
    locations: std.ArrayListUnmanaged(EntityLocation) = .empty,
    archetypes: std.ArrayListUnmanaged(*Archetype) = .empty,
    /// Hash buckets eliminate the full archetype scan. Masks are still
    /// compared within a bucket, so hash collisions are harmless.
    archetype_buckets: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(*Archetype)) = .empty,
    /// Dynamic-registry counterpart to compile-time archetype edges.
    transitions: std.AutoHashMapUnmanaged(TransitionKey, *Archetype) = .empty,
    chunk_pool: ChunkPool,
    resources: Resources,
    observers: Observers = .{},
    tick: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .registry = Registry.init(allocator), .entity_pool = EntityPool.init(allocator), .chunk_pool = ChunkPool.init(allocator), .resources = Resources.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        for (self.archetypes.items) |arch| {
            arch.deinit(self.allocator);
            self.allocator.destroy(arch);
        }

        self.archetypes.deinit(self.allocator);
        var buckets = self.archetype_buckets.valueIterator();
        while (buckets.next()) |bucket| {
            bucket.deinit(self.allocator);
        }
        self.archetype_buckets.deinit(self.allocator);
        self.transitions.deinit(self.allocator);
        self.locations.deinit(self.allocator);
        self.entity_pool.deinit();
        self.chunk_pool.deinit();
        self.resources.deinit();
        self.type_ids.deinit(self.allocator);
        self.registry.deinit();
    }

    pub fn register(self: *Self, desc: registry_mod.ComponentDesc) !ComponentId {
        return self.registry.register(desc);
    }

    /// Reserve the ordinary play-mode allocations ahead of time. This is
    /// intentionally independent of component registration and archetype
    /// shape, so it works for both the dynamic and typed APIs.
    pub fn preWarm(self: *Self, entity_hint: u32, chunk_count: usize) !void {
        if (chunk_count > 0) try self.chunk_pool.preWarm(chunk_count);
        if (entity_hint > 0) {
            try self.entity_pool.reserve(entity_hint);
            try self.ensureLocationCapacity(entity_hint - 1);
        }
    }

    /// Empty the world without discarding registered component metadata or
    /// archetype layouts. Existing entity handles become invalid.
    pub fn clear(self: *Self) void {
        for (self.archetypes.items) |arch| {
            arch.clear();
        }
        self.entity_pool.clear();
        self.locations.clearRetainingCapacity();
        self.tick = 1;
    }

    pub fn registerType(self: *Self, comptime T: type, opts: struct {
        name: ?[]const u8 = null,
        schema_hash: u64,
    }) !ComponentId {
        const key = @typeName(T);
        if (self.type_ids.get(key)) |id| {
            return id;
        }

        const name: []const u8 = blk: {
            if (opts.name) |registered_name| {
                break :blk registered_name;
            }
            break :blk key;
        };

        const hash = opts.schema_hash;
        const id = try self.registry.register(.{ .name = name, .size = @sizeOf(T), .alignment = @max(@alignOf(T), 1), .schema_hash = hash, .fields = comptime fieldDescs(T) });
        try self.type_ids.put(self.allocator, key, id);
        return id;
    }

    pub fn componentId(self: *const Self, comptime T: type) ?ComponentId {
        return self.type_ids.get(@typeName(T));
    }

    pub fn typeId(self: *const Self, comptime T: type) ComponentId {
        return self.componentId(T) orelse @panic("zcs: component type was not registered");
    }

    pub fn setResource(self: *Self, comptime T: type, value: T) !void {
        try self.resources.set(T, value);
    }

    pub fn getResource(self: *Self, comptime T: type) *T {
        return self.resources.get(T);
    }

    pub fn getResourceOrNull(self: *Self, comptime T: type) ?*T {
        return self.resources.getOrNull(T);
    }

    pub fn hasResource(self: *const Self, comptime T: type) bool {
        return self.resources.contains(T);
    }

    pub fn removeResource(self: *Self, comptime T: type) void {
        self.resources.remove(T);
    }

    pub fn advanceTick(self: *Self) void {
        self.tick += 1;
    }

    pub fn currentTick(self: *const Self) u64 {
        return self.tick;
    }

    pub fn setObservers(self: *Self, observers: Observers) void {
        self.observers = observers;
    }

    pub fn notifySpawn(self: *Self, id: EntityID) void {
        if (self.observers.on_spawn) |f| {
            f(self.observers.ctx, id);
        }
    }

    pub fn spawn(self: *Self) !EntityID {
        const id = try self.entity_pool.create();
        errdefer self.entity_pool.destroy(id);
        try self.ensureLocationCapacity(id.index);
        self.locations.items[id.index] = .{};
        self.notifySpawn(id);
        return id;
    }

    pub fn despawn(self: *Self, id: EntityID) void {
        if (!self.entity_pool.isAlive(id)) {
            return;
        }

        if (self.observers.on_despawn) |f| {
            f(self.observers.ctx, id);
        }

        const loc = self.locations.items[id.index];
        if (loc.archetype) |arch| {
            self.removeAt(arch, loc.chunk_idx, loc.row);
        }

        self.locations.items[id.index] = .{};
        self.entity_pool.destroy(id);
    }

    pub fn isAlive(self: *const Self, id: EntityID) bool {
        return self.entity_pool.isAlive(id);
    }

    /// Byte-level structural API.  The payload length must exactly match the
    /// registered descriptor (including zero for a tag component).
    pub fn add(self: *Self, id: EntityID, component: ComponentId, bytes: []const u8) !void {
        const desc = self.registry.desc(component);
        if (bytes.len != desc.size) {
            return error.InvalidComponentPayloadSize;
        }

        if (!self.isAlive(id)) {
            return;
        }

        const loc = &self.locations.items[id.index];
        if (loc.archetype) |src| {
            if (src.has(component)) {
                if (src.column(component)) |col| {
                    @memcpy(Archetype.cell(src.chunks.items[loc.chunk_idx], loc.row, col), bytes);
                }
                self.stamp(src, loc.chunk_idx, component);
                return;
            }
            const dst = try self.transition(src, component, true);
            try self.move(id, loc, src, dst);
            if (dst.column(component)) |col| {
                @memcpy(Archetype.cell(dst.chunks.items[loc.chunk_idx], loc.row, col), bytes);
            }
        } else {
            const arch = try self.singleArchetype(component);
            const result = try arch.appendEntity(self.allocator, id);
            if (arch.column(component)) |col| {
                @memcpy(Archetype.cell(arch.chunks.items[result.chunk_idx], result.row, col), bytes);
            }
            loc.* = .{ .archetype = arch, .chunk_idx = result.chunk_idx, .row = result.row };
            self.stamp(arch, result.chunk_idx, component);
        }

        if (self.observers.on_add) |f| {
            f(self.observers.ctx, id, component);
        }
    }

    pub fn get(self: *Self, id: EntityID, component: ComponentId) ?[]u8 {
        if (!self.isAlive(id)) {
            return null;
        }

        const loc = self.locations.items[id.index];
        const arch = loc.archetype orelse return null;
        const col = arch.column(component) orelse {
            if (arch.has(component)) {
                return &.{};
            }
            return null;
        };
        return Archetype.cell(arch.chunks.items[loc.chunk_idx], loc.row, col);
    }

    pub fn has(self: *const Self, id: EntityID, component: ComponentId) bool {
        if (!self.isAlive(id)) {
            return false;
        }

        const arch = self.locations.items[id.index].archetype orelse return false;
        return arch.has(component);
    }

    pub fn remove(self: *Self, id: EntityID, component: ComponentId) !void {
        if (!self.isAlive(id)) {
            return;
        }

        const loc = &self.locations.items[id.index];
        const src = loc.archetype orelse return;
        if (!src.has(component)) {
            return;
        }

        if (self.observers.on_remove) |f| {
            f(self.observers.ctx, id, component);
        }

        if (src.component_count == 1) {
            self.removeAt(src, loc.chunk_idx, loc.row);
            loc.* = .{};
            return;
        }
        const dst = try self.transition(src, component, false);
        try self.move(id, loc, src, dst);
    }

    pub fn addComponent(self: *Self, id: EntityID, comptime T: type, value: T) !void {
        try self.add(id, self.typeId(T), std.mem.asBytes(&value));
    }

    pub fn removeComponent(self: *Self, id: EntityID, comptime T: type) !void {
        try self.remove(id, self.typeId(T));
    }

    pub fn getComponent(self: *Self, id: EntityID, comptime T: type) ?*T {
        if (@sizeOf(T) == 0) {
            return null;
        }
        const bytes = self.get(id, self.typeId(T)) orelse return null;
        return @ptrCast(@alignCast(bytes.ptr));
    }

    pub fn hasComponent(self: *const Self, id: EntityID, comptime T: type) bool {
        return self.has(id, self.typeId(T));
    }

    pub fn spawnWith(self: *Self, values: anytype) !EntityID {
        const fields = switch (@typeInfo(@TypeOf(values))) {
            .@"struct" => |info| info.fields,
            else => @compileError("spawnWith expects a tuple or struct of component values"),
        };
        comptime {
            for (fields, 0..) |field, i| {
                for (fields[0..i]) |other| {
                    if (field.type == other.type) {
                        @compileError("spawnWith contains duplicate component type " ++ @typeName(field.type));
                    }
                }
            }
        }
        if (comptime fields.len == 0) return self.spawn();

        var ids: [fields.len]ComponentId = undefined;
        inline for (fields, 0..) |field, i| {
            ids[i] = self.typeId(field.type);
        }
        const arch = try self.archetypeForIds(&ids);

        const id = try self.entity_pool.create();
        errdefer self.entity_pool.destroy(id);
        try self.ensureLocationCapacity(id.index);
        const result = try arch.appendEntity(self.allocator, id);
        const chunk = arch.chunks.items[result.chunk_idx];
        inline for (fields, 0..) |field, i| {
            if (@sizeOf(field.type) > 0) {
                const value = @field(values, field.name);
                const col = arch.column(ids[i]).?;
                @memcpy(Archetype.cell(chunk, result.row, col), std.mem.asBytes(&value));
            }
        }
        self.stampAll(arch, result.chunk_idx);
        self.locations.items[id.index] = .{ .archetype = arch, .chunk_idx = result.chunk_idx, .row = result.row };
        self.notifySpawn(id);
        return id;
    }

    pub fn query(self: *Self, comptime spec: query_mod.QuerySpec) query_mod.QueryIterator(spec) {
        return .init(self);
    }

    pub fn ensureLocationCapacity(self: *Self, index: u32) !void {
        const needed = @as(usize, index) + 1;
        if (needed > self.locations.items.len) {
            try self.locations.appendNTimes(self.allocator, .{}, needed - self.locations.items.len);
        }
    }

    fn singleArchetype(self: *Self, component: ComponentId) !*Archetype {
        return self.archetypeForIds(&.{component});
    }

    fn maskWith(self: *Self, old: std.DynamicBitSetUnmanaged, component: ComponentId, present: bool) !std.DynamicBitSetUnmanaged {
        var mask = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.registry.count());
        var bit: usize = 0;
        while (bit < old.bit_length) : (bit += 1) {
            if (old.isSet(bit)) {
                mask.set(bit);
            }
        }
        if (present) {
            mask.set(@intFromEnum(component) - 1);
        } else {
            mask.unset(@intFromEnum(component) - 1);
        }
        return mask;
    }

    fn getOrCreateArchetype(self: *Self, mask: std.DynamicBitSetUnmanaged) !*Archetype {
        var owned_mask = mask;
        const signature = maskSignature(owned_mask);
        if (self.archetype_buckets.get(signature)) |bucket| {
            for (bucket.items) |arch| {
                if (masksEqual(arch.mask, owned_mask)) {
                    owned_mask.deinit(self.allocator);
                    return arch;
                }
            }
        }
        const arch = self.allocator.create(Archetype) catch |err| {
            owned_mask.deinit(self.allocator);
            return err;
        };
        errdefer self.allocator.destroy(arch);
        arch.* = try Archetype.init(self.allocator, &self.registry, owned_mask, &self.chunk_pool);
        errdefer arch.deinit(self.allocator);
        try self.archetypes.append(self.allocator, arch);
        errdefer _ = self.archetypes.pop();
        const bucket = try self.archetype_buckets.getOrPut(self.allocator, signature);
        if (!bucket.found_existing) bucket.value_ptr.* = .empty;
        try bucket.value_ptr.append(self.allocator, arch);
        return arch;
    }

    fn archetypeForIds(self: *Self, ids: []const ComponentId) !*Archetype {
        const signature = idsSignature(ids);
        if (self.archetype_buckets.get(signature)) |bucket| {
            for (bucket.items) |arch| {
                if (arch.hasExactly(ids)) return arch;
            }
        }
        var mask = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.registry.count());
        for (ids) |id| mask.set(@intFromEnum(id) - 1);
        return self.getOrCreateArchetype(mask);
    }

    fn transition(self: *Self, source: *Archetype, component: ComponentId, adding: bool) !*Archetype {
        const key = TransitionKey{ .source = source, .component = component, .adding = adding };
        if (self.transitions.get(key)) |target| return target;
        const mask = try self.maskWith(source.mask, component, adding);
        const target = try self.getOrCreateArchetype(mask);
        try self.transitions.put(self.allocator, key, target);
        return target;
    }

    fn move(self: *Self, id: EntityID, loc: *EntityLocation, src: *Archetype, dst: *Archetype) !void {
        const old_chunk = src.chunks.items[loc.chunk_idx];
        const old_row = loc.row;
        const result = try dst.appendEntity(self.allocator, id);
        const new_chunk = dst.chunks.items[result.chunk_idx];
        for (src.columns.items) |col| {
            if (dst.column(col.id)) |dst_col| {
                @memcpy(Archetype.cell(new_chunk, result.row, dst_col), Archetype.cell(old_chunk, old_row, col));
            }
        }
        self.stampAll(dst, result.chunk_idx);
        self.removeAt(src, loc.chunk_idx, loc.row);
        loc.* = .{ .archetype = dst, .chunk_idx = result.chunk_idx, .row = result.row };
    }

    fn removeAt(self: *Self, arch: *Archetype, chunk_idx: u32, row: u16) void {
        if (arch.removeEntity(chunk_idx, row)) |moved| {
            self.locations.items[moved.index] = .{ .archetype = arch, .chunk_idx = chunk_idx, .row = row };
        }
    }

    pub fn stamp(self: *Self, arch: *Archetype, chunk_idx: u32, component: ComponentId) void {
        if (arch.tickIndex(component)) |index| {
            self.stampAt(arch, chunk_idx, index);
        }
    }

    pub fn stampAt(self: *Self, arch: *Archetype, chunk_idx: u32, index: usize) void {
        arch.change_ticks.items[chunk_idx][index] = self.tick;
    }

    fn stampAll(self: *Self, arch: *Archetype, chunk_idx: u32) void {
        for (arch.change_ticks.items[chunk_idx]) |*tick| {
            tick.* = self.tick;
        }
    }

    fn fieldDescs(comptime T: type) []const registry_mod.FieldDesc {
        const info = @typeInfo(T);
        if (info != .@"struct") {
            return &.{};
        }
        const fields = info.@"struct".fields;
        const Table = struct {
            const value = blk: {
                var result: [fields.len]registry_mod.FieldDesc = undefined;
                for (fields, 0..) |field, i| {
                    result[i] = .{ .name = field.name, .type = fieldType(field.type), .offset = @offsetOf(T, field.name) };
                }
                break :blk result;
            };
        };
        return &Table.value;
    }

    fn fieldType(comptime T: type) registry_mod.FieldType {
        return switch (@typeInfo(T)) {
            .bool => .bool,
            .int => .integer,
            .float => .float,
            .@"enum" => .enum_,
            .array => .array,
            .@"struct" => .struct_,
            .pointer => .pointer,
            else => .@"opaque",
        };
    }

    fn masksEqual(a: std.DynamicBitSetUnmanaged, b: std.DynamicBitSetUnmanaged) bool {
        const n = @max(a.bit_length, b.bit_length);
        var bit: usize = 0;
        while (bit < n) : (bit += 1) {
            const av = bit < a.bit_length and a.isSet(bit);
            const bv = bit < b.bit_length and b.isSet(bit);
            if (av != bv) {
                return false;
            }
        }
        return true;
    }

    /// Order-independent component-set signature. It chooses a tiny lookup
    /// bucket only; every candidate is checked by its full mask, so no hash
    /// property is part of correctness.
    fn idsSignature(ids: []const ComponentId) u64 {
        var signature: u64 = @as(u64, @intCast(ids.len)) *% 0x9e3779b97f4a7c15;
        for (ids) |id| signature ^= componentSignature(id);
        return signature;
    }

    fn maskSignature(mask: std.DynamicBitSetUnmanaged) u64 {
        var signature: u64 = 0;
        var count: usize = 0;
        var bit: usize = 0;
        while (bit < mask.bit_length) : (bit += 1) {
            if (mask.isSet(bit)) {
                signature ^= componentSignature(@enumFromInt(@as(u32, @intCast(bit + 1))));
                count += 1;
            }
        }
        return signature ^ (@as(u64, @intCast(count)) *% 0x9e3779b97f4a7c15);
    }

    fn componentSignature(id: ComponentId) u64 {
        var value: u64 = @intFromEnum(id);
        value +%= 0x9e3779b97f4a7c15;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }
};
