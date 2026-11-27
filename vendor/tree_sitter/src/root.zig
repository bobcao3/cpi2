pub const api = @import("api");

pub const Grammar = enum {
    zig,
    python,
    javascript,
    typescript,
    tsx,
    rust,
    go,
    c,
    cpp,
    bash,
    lua,
    json,
    yaml,
    toml,
    css,
    html,
    java,
    ruby,
    nix,
    c_sharp,
    php,

    pub fn language(self: Grammar) *const api.TSLanguage {
        return switch (self) {
            .zig => tree_sitter_zig(),
            .python => tree_sitter_python(),
            .javascript => tree_sitter_javascript(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
            .rust => tree_sitter_rust(),
            .go => tree_sitter_go(),
            .c => tree_sitter_c(),
            .cpp => tree_sitter_cpp(),
            .bash => tree_sitter_bash(),
            .lua => tree_sitter_lua(),
            .json => tree_sitter_json(),
            .yaml => tree_sitter_yaml(),
            .toml => tree_sitter_toml(),
            .css => tree_sitter_css(),
            .html => tree_sitter_html(),
            .java => tree_sitter_java(),
            .ruby => tree_sitter_ruby(),
            .nix => tree_sitter_nix(),
            .c_sharp => tree_sitter_c_sharp(),
            .php => tree_sitter_php(),
        };
    }

    pub fn highlights(self: Grammar) []const u8 {
        return switch (self) {
            .cpp => @embedFile("c") ++ "\n" ++ @embedFile("cpp"),
            .typescript, .tsx => @embedFile("javascript") ++ "\n" ++ @embedFile("typescript"),
            inline else => |grammar| @embedFile(@tagName(grammar)),
        };
    }
};

extern fn tree_sitter_zig() *const api.TSLanguage;
extern fn tree_sitter_python() *const api.TSLanguage;
extern fn tree_sitter_javascript() *const api.TSLanguage;
extern fn tree_sitter_typescript() *const api.TSLanguage;
extern fn tree_sitter_tsx() *const api.TSLanguage;
extern fn tree_sitter_rust() *const api.TSLanguage;
extern fn tree_sitter_go() *const api.TSLanguage;
extern fn tree_sitter_c() *const api.TSLanguage;
extern fn tree_sitter_cpp() *const api.TSLanguage;
extern fn tree_sitter_bash() *const api.TSLanguage;
extern fn tree_sitter_lua() *const api.TSLanguage;
extern fn tree_sitter_json() *const api.TSLanguage;
extern fn tree_sitter_yaml() *const api.TSLanguage;
extern fn tree_sitter_toml() *const api.TSLanguage;
extern fn tree_sitter_css() *const api.TSLanguage;
extern fn tree_sitter_html() *const api.TSLanguage;
extern fn tree_sitter_java() *const api.TSLanguage;
extern fn tree_sitter_ruby() *const api.TSLanguage;
extern fn tree_sitter_nix() *const api.TSLanguage;
extern fn tree_sitter_c_sharp() *const api.TSLanguage;
extern fn tree_sitter_php() *const api.TSLanguage;
