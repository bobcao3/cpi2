//! Terminal entry points and presentation used by the CLI.

const interactive = @import("tui/interactive.zig");

pub const run = interactive.run;
pub const chooseStartupWorkspace = interactive.chooseStartupWorkspace;
pub const selectStartupSession = interactive.selectStartupSession;
pub const StartupSelection = interactive.StartupSelection;
pub const ClipboardX11 = @import("tui/composer.zig").ClipboardX11;
pub const Theme = @import("tui/style.zig").Theme;
pub const cleanText = @import("tui/transcript.zig").markdown.clean;

pub const Presentation = @import("tui/UiPresentation.zig");
pub const Timings = @import("tui/Timings.zig");
pub const Wake = @import("tui/UiWake.zig");
