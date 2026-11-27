const std = @import("std");
const kit = @import("kit");
const clock = kit.hw.hwclock;
const Histogram = kit.timing.Histogram;

started: kit.timing.Timestamp,
main_to_first_present: Histogram = .{},
draw: Histogram = .{},
key_to_next_present: Histogram = .{},
oldest_text_delta_to_next_present: Histogram = .{},

pub fn report(self: *const @This()) void {
    inline for (.{ "main_to_first_present", "draw", "key_to_next_present", "oldest_text_delta_to_next_present" }) |name| {
        const h = &@field(self, name);
        if (h.count != 0) std.debug.print("cpi_timing {{\"metric\":\"{s}\",\"n\":{d},\"p50_upper_ns\":{d},\"p95_upper_ns\":{d},\"max_ns\":{d}}}\n", .{
            name, h.count, clock.toNanoseconds(h.percentileUpperTicks(50).?), clock.toNanoseconds(h.percentileUpperTicks(95).?), clock.toNanoseconds(h.max_ticks),
        });
    }
}
