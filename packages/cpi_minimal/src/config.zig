//! Launch configuration, user paths, and saved preferences.

const file = @import("config/Config.zig");

pub const Config = file.Config;
pub const QuietStartup = file.QuietStartup;
pub const Paths = @import("config/Paths.zig").Paths;
pub const Settings = @import("config/Settings.zig");
