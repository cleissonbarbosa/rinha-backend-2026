const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const D: usize = 14;
const K: usize = 5;
const VLEN: usize = 8;

const Vec32 = @Vector(VLEN, f32);
const Vec16 = @Vector(VLEN, f16);

var n_vecs: usize = 0;
var dims_data: [*]align(64) const f16 = undefined;
var labels_data: [*]const u8 = undefined;

fn mmapRO(path: []const u8, expected_align: usize) ![]align(std.mem.page_size) const u8 {
    _ = expected_align;
    const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(fd);

    const st = try posix.fstat(fd);
    const size: usize = @intCast(st.size);

    const mem = try posix.mmap(
        null,
        size,
        posix.PROT.READ,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    // WILLNEED triggers async readahead; we deliberately skip SEQUENTIAL because
    // it tells the kernel to evict pages right after reading them, which is the
    // exact opposite of what we want — every query re-scans the whole dataset.
    posix.madvise(mem.ptr, size, posix.MADV.WILLNEED) catch {};

    // Pre-fault every page so the first few queries don't take the page-fault
    // hit. Touching one byte per page is enough to populate the page table.
    const page_size = std.mem.page_size;
    var fault_sink: u8 = 0;
    var off: usize = 0;
    while (off < size) : (off += page_size) {
        fault_sink ^= mem[off];
    }
    asm volatile (""
        :
        : [s] "r" (fault_sink),
        : "memory"
    );

    return mem[0..size];
}

fn initInternal(vec_path: []const u8, lbl_path: []const u8) !void {
    const lbl_mem = try mmapRO(lbl_path, 1);
    const vec_mem = try mmapRO(vec_path, 64);

    const n = lbl_mem.len;
    if (vec_mem.len != D * n * @sizeOf(f16)) return error.SizeMismatch;
    if ((@intFromPtr(vec_mem.ptr) % 16) != 0) return error.Misaligned;

    n_vecs = n;
    labels_data = lbl_mem.ptr;
    dims_data = @ptrCast(@alignCast(vec_mem.ptr));
}

export fn vc_init(vec_path: [*:0]const u8, lbl_path: [*:0]const u8) c_int {
    const v = std.mem.sliceTo(vec_path, 0);
    const l = std.mem.sliceTo(lbl_path, 0);
    initInternal(v, l) catch |err| {
        const msg = @errorName(err);
        std.debug.print("vc_init failed: {s}\n", .{msg});
        return -1;
    };
    return 0;
}

export fn vc_count() usize {
    return n_vecs;
}

export fn vc_query(query_ptr: [*]const f32) c_int {
    if (n_vecs == 0) return 0;

    var query: [D]f32 = undefined;
    {
        var i: usize = 0;
        while (i < D) : (i += 1) query[i] = query_ptr[i];
    }

    var top_dist = [_]f32{std.math.inf(f32)} ** K;
    var top_idx = [_]u32{0} ** K;

    const dims_ptr = dims_data;
    const n = n_vecs;
    const labels_ptr = labels_data;

    const n_chunks = n / VLEN;
    var chunk: usize = 0;
    while (chunk < n_chunks) : (chunk += 1) {
        const offset = chunk * VLEN;
        var dist: Vec32 = @splat(@as(f32, 0.0));

        comptime var d: usize = 0;
        inline while (d < D) : (d += 1) {
            const dim_base = dims_ptr + d * n;
            const slice_ptr: *const [VLEN]f16 = @ptrCast(dim_base + offset);
            const dim_vec16: Vec16 = slice_ptr.*;
            const dim_vec: Vec32 = @floatCast(dim_vec16);
            const q: Vec32 = @splat(query[d]);
            const diff = q - dim_vec;
            dist = @mulAdd(Vec32, diff, diff, dist);
        }

        comptime var k: usize = 0;
        inline while (k < VLEN) : (k += 1) {
            const d_val = dist[k];
            if (d_val < top_dist[K - 1]) {
                const idx: u32 = @intCast(offset + k);
                var pos: usize = K - 1;
                while (pos > 0 and top_dist[pos - 1] > d_val) : (pos -= 1) {
                    top_dist[pos] = top_dist[pos - 1];
                    top_idx[pos] = top_idx[pos - 1];
                }
                top_dist[pos] = d_val;
                top_idx[pos] = idx;
            }
        }
    }

    var i_rem: usize = n_chunks * VLEN;
    while (i_rem < n) : (i_rem += 1) {
        var dist: f32 = 0.0;
        var d: usize = 0;
        while (d < D) : (d += 1) {
            const v: f32 = @floatCast(dims_ptr[d * n + i_rem]);
            const diff = query[d] - v;
            dist += diff * diff;
        }
        if (dist < top_dist[K - 1]) {
            const idx: u32 = @intCast(i_rem);
            var pos: usize = K - 1;
            while (pos > 0 and top_dist[pos - 1] > dist) : (pos -= 1) {
                top_dist[pos] = top_dist[pos - 1];
                top_idx[pos] = top_idx[pos - 1];
            }
            top_dist[pos] = dist;
            top_idx[pos] = idx;
        }
    }

    var fraud_count: c_int = 0;
    var k: usize = 0;
    while (k < K) : (k += 1) {
        if (labels_ptr[top_idx[k]] != 0) fraud_count += 1;
    }
    return fraud_count;
}
