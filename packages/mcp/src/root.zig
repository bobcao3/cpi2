//! Reusable Model Context Protocol (MCP) client and gateway.
//!
//! This package owns protocol semantics, transports, configuration validation,
//! connection lifecycle, request/response correlation, notifications, and
//! catalog state. It has no dependency on a particular agent harness. Products
//! provide decoded configuration, a policy around the exposed operations, and
//! their own tool-registration/UI integration.

const std = @import("std");

pub const Config = @import("Config.zig").Config;
pub const Server = @import("Config.zig").Server;
pub const Entry = @import("Config.zig").Entry;
pub const Json = @import("Json.zig");
pub const Sse = @import("Sse.zig");
pub const Transport = @import("Transport.zig");
pub const Client = @import("Client.zig").Client;
pub const Tool = @import("Client.zig").Tool;
pub const Changes = @import("Client.zig").Changes;
pub const Gateway = @import("Gateway.zig").Gateway;
pub const Binding = @import("Gateway.zig").Binding;

test {
    _ = Config;
    _ = Json;
    _ = Sse;
    _ = Transport;
    _ = @import("Client.zig");
    _ = @import("Gateway.zig");
    _ = @import("HttpTransport.zig");
}
