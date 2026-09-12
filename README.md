# zcs (Fusion Component System)

An archetype-based Entity Component System for Zig 0.16, with SoA memory layout and comptime query validation.

Designed for the [Fusion Game Engine](https://github.com/Fusion-Engine-Labs) but fully standalone — usable in any Zig project that needs high-performance ECS.

## Features

- **Archetype SoA layout** — components are stored in Structure-of-Arrays within 16KB cache-aligned chunks for maximum iteration throughput.
- **Comptime query validation** — read vs write access is enforced at compile time. Accessing a component you didn't declare is a compile error.
- **Zero-sized type (ZST) tags** — tag components like `Player` or `Enemy` affect archetype matching but allocate no storage.
- **O(1) entity operations** — 64-bit generational `EntityID` (32-bit index + 32-bit generation) with free-list reuse and stale handle detection. Generations start at 1, so `nil` is raw zero (zero-initialized memory is a nil handle); a slot that exhausts its generations is retired rather than wrapped, so a stale handle can never alias a new entity.
- **Edge-cached archetype transitions** — adding or removing a component reuses a cached pointer to the target archetype.
- **Bundle spawn** — `world.spawnWith(.{ Position{...}, Velocity{...} })` builds an entity in its final archetype with a single insertion (no per-component churn); also available on the CommandBuffer.
- **Cached queries** — matching archetype lists are cached per query shape and rebuilt only when a new archetype appears.
- **Swap-remove deletion** — O(1) unordered entity removal with automatic back-fill from the last slot.
- **CommandBuffer** — deferred structural mutations (spawn, spawnWith, despawn, add/remove component) safe to use during iteration.
- **Change detection** — per-chunk/per-component write ticks; `view.changedSince(T, tick)` skips unmodified data. Spawns and archetype moves count as changes, so new data is never skipped.
- **Schedule** — phased system execution (pre_update, update, post_update, render) with scoped delta time, automatic CommandBuffer flushing, and cleanup of pending commands on errors. The application owns frame counting.
- **Resources** — world-owned, type-erased singleton storage for global game state (delta time, frame count, etc.), readable from any system.
- **Lifecycle observers** — opt-in `on_spawn`/`on_despawn`/`on_add`/`on_remove` callbacks with near-zero cost when unused.
- **Diagnostics** — `world.stats()` reports entity/archetype/chunk counts, occupancy, and memory use.
- **SparseSet** — generation-aware associative container for per-entity side data (debug names, editor metadata).
- **Pre-warming & reset** — `world.preWarm(...)` to pre-allocate, `world.clear()` for fast scene reloads.
- **Zero dependencies** — built entirely on `std`.

## Requirements

- Zig 0.16+

## Installing

Add zcs as a dependency in your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Fusion-Engine-Labs/zcs.git
```

Then in your `build.zig`:

```zig
const zcs_dep = b.dependency("zcs", .{
    .target = target,
    .optimize = optimize,
});
const zcs_mod = zcs_dep.module("zcs");
exe.root_module.addImport("zcs", zcs_mod);
```

## Running the example

```sh
zig build example
```

## Running tests

```sh
zig build test --summary all
```

## Usage

### Defining components

Components are plain Zig structs. Zero-sized structs work as tags:

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { vx: f32, vy: f32 };
const Health = struct { hp: i32, max_hp: i32 };
const Player = struct {}; // ZST tag
const Enemy = struct {};  // ZST tag
```

### Creating a registry and world

Create a world and register its component types:

```zig
const zcs = @import("zcs");

var world = zcs.World.init(allocator);
defer world.deinit();
inline for (.{ Position, Velocity, Health, Player, Enemy }) |T| {
    _ = try world.registerType(T, .{ .schema_hash = 0 });
}
```

### Spawning entities

```zig
const entity = try world.spawn();
try world.addComponent(entity, Position, .{ .x = 0, .y = 0 });
try world.addComponent(entity, Velocity, .{ .vx = 1, .vy = 2 });
try world.addComponent(entity, Player, .{});
```

### Querying — batch iteration

Batch iteration yields one `View` per chunk, giving you slices for SIMD-friendly loops:

```zig
var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
while (iter.nextChunk()) |view| {
    const positions = view.write(Position);
    const velocities = view.read(Velocity);
    for (positions, velocities) |*pos, vel| {
        pos.x += vel.vx;
        pos.y += vel.vy;
    }
}
```

### Querying — per-entity iteration

Per-entity iteration yields one `Row` at a time, convenient for logic that needs `entity()`:

```zig
var iter = world.query(.{
    .write = &.{Health},
    .read = &.{Position},
    .with = &.{Enemy},
    .without = &.{Disabled},
});
while (iter.each()) |row| {
    const pos = row.read(Position);
    const hp = row.write(Health);
    if (@sqrt(pos.x * pos.x + pos.y * pos.y) < 5.0) {
        hp.hp -= 10;
    }
}
```

### Deferred mutations with CommandBuffer

Structural changes during iteration are buffered and applied on `flush()`:

```zig
var cmd = zcs.CommandBuffer.init(&world);
defer cmd.deinit();

const e = try cmd.spawn();
try cmd.addComponent(e, Position, .{ .x = 0, .y = 0 });
try cmd.addComponent(e, Enemy, .{});

try cmd.flush();
```

### Systems and Schedule

Systems are plain functions. The Schedule runs them in phases with automatic CommandBuffer flushing between each:

```zig
fn movementSystem(world: *zcs.World, _: *zcs.CommandBuffer) !void {
    const dt = world.getResource(zcs.DeltaTime).seconds;
    var iter = world.query(.{ .write = &.{Position}, .read = &.{Velocity} });
    while (iter.nextChunk()) |view| {
        const positions = view.write(Position);
        const velocities = view.read(Velocity);
        for (positions, velocities) |*pos, vel| {
            pos.x += vel.vx * dt;
            pos.y += vel.vy * dt;
        }
    }
}

try zcs.Schedule.run(&world, &cmd, .{ .delta_time = 1.0 / 60.0 }, .{
    .pre_update = &.{gravitySystem},
    .update = &.{ movementSystem, damageSystem },
    .post_update = &.{collisionSystem},
    .render = &.{renderSystem},
});
```

`Schedule.run` executes the supplied schedule once. It exposes
`zcs.DeltaTime{ .seconds = context.delta_time }` for that invocation and restores
the previous resource, or its absence, on every return path. The context accepts
finite, nonnegative deltas, including zero. It does not create or increment
`FrameCount`: the application owns frame and fixed-simulation counters and decides
how often to call the runner. Each invocation advances `World.currentTick()` for
ECS change detection, independently of those application counters.

Nested invocations restore their caller's timing and isolate pending commands,
including when they share a command buffer. Each phase flushes only commands
belonging to its invocation; the caller's pending prefix remains queued. Commands
queued before a top-level invocation starts are included in that invocation.
A nested invocation's successful flushes are committed even if the caller later
fails.

When a system fails, the runner discards its unflushed commands and reclaims
entities created by those pending spawn commands. If a flush fails midway,
already-applied commands remain committed and the remaining commands are
discarded. Direct component writes also remain committed. This is command cleanup,
not a transaction over the ECS world. `CommandBuffer.discard()` exposes the same
cleanup explicitly, and `deinit()` discards abandoned pending spawns. Component
payload bytes are copied shallowly; callers retain responsibility for allocations
referenced by their fields.

### Resources

Type-safe singleton storage for global state:

```zig
const DeltaTime = struct { dt: f32 };
const FrameCount = struct { count: u64 };

var resources = zcs.Resources.init(allocator);
defer resources.deinit();

try resources.set(DeltaTime, .{ .dt = 0.016 });
try resources.set(FrameCount, .{ .count = 0 });

const dt = resources.get(DeltaTime).dt;
```

Temporary resource overrides can be installed without allocating:

```zig
var value: zcs.DeltaTime = .{ .seconds = 0.01 };
var scope: zcs.Resources.Scope = undefined;
world.resources.pushScope(zcs.DeltaTime, &value, &scope);
defer scope.deinit();
// world.getResource(zcs.DeltaTime) now reads value.
```

Keep the value and scope at stable addresses, and close scopes in reverse order.
Within a scope, `setResource` updates the borrowed value and `removeResource`
hides it until it is set again or the scope closes. The owned resource underneath
is untouched. Pointers to scoped resources, including scheduler-provided
`DeltaTime`, must not escape their invocation. Nested scopes are synchronous;
resource stores and command buffers require exclusive access during execution.

### SparseSet

Generation-aware associative container for per-entity side data:

```zig
const DebugName = struct { name: []const u8 };

var names = zcs.SparseSet(DebugName).init(allocator);
defer names.deinit();

try names.set(entity, .{ .name = "Hero" });
if (names.get(entity)) |n| {
    std.debug.print("Name: {s}\n", .{n.name});
}
```

## Query spec

| Field     | Type           | Description                                  |
| --------- | -------------- | -------------------------------------------- |
| `read`    | `[]const type` | Components accessed as `[]const T`           |
| `write`   | `[]const type` | Components accessed as `[]T` (also readable) |
| `with`    | `[]const type` | Required components (not accessed)           |
| `without` | `[]const type` | Excluded components                          |

## Schedule phases

| Phase         | Intended use                     |
| ------------- | -------------------------------- |
| `pre_update`  | Physics forces, input processing |
| `update`      | Core game logic, movement, AI    |
| `post_update` | Collision resolution, cleanup    |
| `render`      | Drawing, UI updates              |

## Benchmarks

Run the built-in benchmark suite:

```sh
zig build bench
```

### Configuration

All parameters are optional:

```sh
zig build bench -- [options]
```

| Flag           | Default | Description                                 |
| -------------- | ------- | ------------------------------------------- |
| `--entities=N` | 10000   | Number of entities for iteration benchmarks |
| `--iters=N`    | 100     | Measured samples per benchmark              |
| `--warmup=N`   | 10      | Warmup iterations before measuring          |

### What it measures

- **Spawn empty** — entity creation overhead
- **Spawn with components** — entity creation + component assignment
- **Despawn** — entity removal with swap-remove
- **Iterate 2 components** — batch query over Position + Velocity
- **Iterate 4 components** — batch query over four component types
- **Archetype move** — add/remove component triggering archetype transition
- **Command buffer** — deferred spawn + component add + flush
- **Game frame** — full Schedule tick with multiple systems
