#include "bridge.h"
#include <luau.h>
#include <math.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* Codes map to runtime.zig; Lua errors never cross a Zig stack frame. */
enum { OOM = 1, HEAP = 2, EXECUTION = 3, SYNTAX = 4, RUNTIME = 5,
       SHAPE = 6, UNKNOWN = 7, NUMBER = 8, CYCLE = 10, META = 11 };

static void *allocate(void *ud, void *ptr, size_t old, size_t size)
{
    cpi_registry_runtime *r = ud;
    if (!ptr) old = 0;
    void *next = r->alloc(r->allocator, ptr, old, size);
    if (!size || next) r->used = r->used - old + size;
    else r->error = OOM;
    return next;
}

static cpi_registry_runtime *context(lua_State *L)
{
    return lua_callbacks(L)->userdata;
}

static void interrupt(lua_State *L, int gc)
{
    cpi_registry_runtime *r = context(L);
    if (gc < 0 && r->budget && !--r->budget) {
        r->error = EXECUTION;
        lua_break(L);
    }
}

static void fail(lua_State *L, int code)
{
    if (!context(L)->error) context(L)->error = code;
    luaL_error(L, "invalid model registry");
}

static void emit(lua_State *L, int event, const char *bytes, size_t length, double number)
{
    cpi_registry_runtime *r = context(L);
    int error = r->sink(r->sink_context, event, bytes, length, number);
    if (error) fail(L, error);
}

static void string(lua_State *L, const char *s, size_t length)
{
    emit(L, CPI_STRING, s, length, 0);
}

enum kind { CONFIG, PROVIDERS, PROVIDER, MODELS, MODEL, PRICING, IMAGE_RESIZE, TEXTS, TEXT, UINT32, UINT53, PRICE };
struct field { const char *name; enum kind kind; int required; };
static const struct field config[] = {{"version", UINT32, 1}, {"providers", PROVIDERS, 1}};
static const struct field provider[] = {
    {"id", TEXT, 1}, {"name", TEXT, 1}, {"base_url", TEXT, 1}, {"api_key_env", TEXT, 1},
    {"api", TEXT, 0}, {"source_url", TEXT, 0}, {"retrieved_at", TEXT, 0}, {"models", MODELS, 1}};
static const struct field model[] = {
    {"id", TEXT, 1}, {"name", TEXT, 1}, {"api", TEXT, 0}, {"context_window", UINT53, 0},
    {"max_output_tokens", UINT32, 0}, {"pricing", PRICING, 0}, {"source_url", TEXT, 0},
    {"transports", TEXTS, 0}, {"reasoning_efforts", TEXTS, 0}, {"image_resize", IMAGE_RESIZE, 0}};
static const struct field pricing[] = {
    {"input", PRICE, 0}, {"output", PRICE, 0}, {"cache_read", PRICE, 0}, {"cache_write", PRICE, 0}};
static const struct field image_resize[] = {
    {"max_width", UINT32, 0}, {"max_height", UINT32, 0}, {"max_bytes", UINT53, 0}, {"jpeg_quality", UINT32, 0}};

static void reserve_ancestor(lua_State *L, cpi_registry_runtime *r, unsigned depth)
{
    if ((size_t)depth < r->ancestor_capacity) return;
    size_t capacity = (size_t)depth + 1;
    if (capacity > SIZE_MAX / sizeof(void *)) fail(L, OOM);
    void *next = r->alloc(r->allocator, r->ancestors, r->ancestor_capacity * sizeof(void *), capacity * sizeof(void *));
    if (!next) fail(L, OOM);
    r->ancestors = next;
    r->ancestor_capacity = capacity;
}

static void value(lua_State *L, int index, enum kind kind, unsigned depth)
{
    cpi_registry_runtime *r = context(L);

    if (kind == TEXT) {
        if (lua_type(L, index) != LUA_TSTRING) fail(L, SHAPE);
        size_t length;
        const char *s = lua_tolstring(L, index, &length);
        string(L, s, length);
        return;
    }
    if (kind == UINT32 || kind == UINT53 || kind == PRICE) {
        if (lua_type(L, index) != LUA_TNUMBER) fail(L, NUMBER);
        double n = lua_tonumber(L, index);
        double max = kind == UINT32 ? 4294967295.0 : 9007199254740991.0;
        if (!isfinite(n) || n < 0 || (kind != PRICE && (n > max || floor(n) != n))) fail(L, NUMBER);
        emit(L, CPI_NUMBER, NULL, 0, n);
        return;
    }
    if (lua_type(L, index) != LUA_TTABLE) fail(L, SHAPE);
    if (lua_getmetatable(L, index)) fail(L, META);
    const void *identity = lua_topointer(L, index);
    for (unsigned i = 0; i < depth; ++i) if (r->ancestors[i] == identity) fail(L, CYCLE);
    reserve_ancestor(L, r, depth);
    r->ancestors[depth] = identity;
    if (!lua_checkstack(L, 8)) fail(L, OOM);
    index = lua_absindex(L, index);
    int array = kind == PROVIDERS || kind == MODELS || kind == TEXTS;
    const struct field *fields = NULL;
    size_t count = 0;
    switch (kind) {
        case CONFIG: fields = config; count = sizeof(config)/sizeof(*config); break;
        case PROVIDER: fields = provider; count = sizeof(provider)/sizeof(*provider); break;
        case MODEL: fields = model; count = sizeof(model)/sizeof(*model); break;
        case PRICING: fields = pricing; count = sizeof(pricing)/sizeof(*pricing); break;
        case IMAGE_RESIZE: fields = image_resize; count = sizeof(image_resize)/sizeof(*image_resize); break;
        default: break;
    }
    size_t entries = 0;
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (entries == INT_MAX) fail(L, SHAPE);
        ++entries;
        if (array) {
            if (lua_type(L, -2) != LUA_TNUMBER) fail(L, SHAPE);
            double key = lua_tonumber(L, -2);
            if (key < 1 || key > INT_MAX || floor(key) != key) fail(L, SHAPE);
        } else {
            if (lua_type(L, -2) != LUA_TSTRING) fail(L, SHAPE);
            size_t length;
            const char *key = lua_tolstring(L, -2, &length);
            size_t i;
            for (i = 0; i < count; ++i)
                if (strlen(fields[i].name) == length && !memcmp(fields[i].name, key, length)) break;
            if (i == count) fail(L, UNKNOWN);
        }
        lua_pop(L, 1);
    }
    emit(L, array ? CPI_ARRAY : CPI_OBJECT, NULL, 0, 0);
    for (size_t i = 0; i < (array ? entries : count); ++i) {
        if (array) lua_rawgeti(L, index, (int)i + 1);
        else lua_rawgetfield(L, index, fields[i].name);
        if (lua_isnil(L, -1)) {
            if (array || fields[i].required) fail(L, SHAPE);
            lua_pop(L, 1);
            continue;
        }
        if (!array) emit(L, CPI_KEY, fields[i].name, strlen(fields[i].name), 0);
        value(L, -1, array ? (kind == PROVIDERS ? PROVIDER : kind == MODELS ? MODEL : TEXT) : fields[i].kind, depth + 1);
        lua_pop(L, 1);
    }
    emit(L, CPI_END, NULL, 0, 0);
    r->ancestors[depth] = NULL;
}

static int initialize(lua_State *L)
{
    cpi_registry_runtime *r = lua_touserdata(L, 1);
    lua_gc(L, LUA_GCSTOP, 0);
    lua_pushcfunction(L, luaopen_base, "base");
    lua_pushstring(L, "");
    lua_call(L, 1, 0);
    lua_newtable(L);
    const char *allowed[] = {"assert", "error", "ipairs", "next", "pairs", "pcall", "select", "tonumber", "tostring", "type", "unpack", "xpcall", "rawequal", "rawget", "rawset", "getmetatable", "setmetatable", NULL};
    for (const char **name = allowed; *name; ++name) {
        lua_getglobal(L, *name);
        lua_setfield(L, -2, *name);
    }
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "_G");
    lua_replace(L, LUA_GLOBALSINDEX);
    const luaL_Reg libraries[] = {{"math", luaopen_math}, {"string", luaopen_string}, {"table", luaopen_table}, {NULL, NULL}};
    for (const luaL_Reg *lib = libraries; lib->func; ++lib) {
        lua_pushcfunction(L, lib->func, lib->name);
        lua_pushstring(L, lib->name);
        lua_call(L, 1, 0);
    }
    luaL_sandbox(L);
    luaL_sandboxthread(L);
    lua_State *thread = lua_newthread(L);
    r->thread = thread;
    lua_ref(L, -1);
    lua_pop(L, 1);
    int status = luau_load(L, "=model-registry", r->bytecode, r->bytecode_length, 0);
    if (status) fail(L, status == LUA_ERRMEM ? OOM : SYNTAX);
    lua_xmove(L, thread, 1);
    return 0;
}


struct cpi_registry_table_frame {
    const void *identity;
    int index, array;
    size_t entries, next;
};

static void push_table(lua_State *L, struct cpi_registry_table_frame table)
{
    cpi_registry_runtime *r = context(L);
    if (r->table_count == r->table_capacity) {
        size_t previous = r->table_capacity;
        if (previous > SIZE_MAX / sizeof(table) / 2) fail(L, OOM);
        size_t capacity = previous ? previous * 2 : 16;
        void *next = r->alloc(r->allocator, r->tables, previous * sizeof(table), capacity * sizeof(table));
        if (!next) fail(L, OOM);
        r->tables = next;
        r->table_capacity = capacity;
    }
    r->tables[r->table_count++] = table;
}

static int begin_generic_value(lua_State *L, int index)
{
    cpi_registry_runtime *r = context(L);
    int type = lua_type(L, index);
    if (type == LUA_TNIL) { emit(L, CPI_NULL, NULL, 0, 0); return 0; }
    if (type == LUA_TBOOLEAN) {
        emit(L, CPI_BOOL, NULL, 0, lua_toboolean(L, index));
        return 0;
    }
    if (type == LUA_TNUMBER) {
        double n = lua_tonumber(L, index);
        if (!isfinite(n)) fail(L, NUMBER);
        emit(L, CPI_NUMBER, NULL, 0, n);
        return 0;
    }
    if (type == LUA_TSTRING) {
        size_t length;
        const char *s = lua_tolstring(L, index, &length);
        string(L, s, length);
        return 0;
    }
    if (type != LUA_TTABLE) fail(L, SHAPE);
    if (lua_getmetatable(L, index)) fail(L, META);
    const void *identity = lua_topointer(L, index);
    for (size_t i = 0; i < r->table_count; ++i) if (r->tables[i].identity == identity) fail(L, CYCLE);
    if (!lua_checkstack(L, 8)) fail(L, OOM);
    index = lua_absindex(L, index);
    size_t entries = 0, numeric = 0, text = 0;
    double maximum = 0;
    lua_pushnil(L);
    while (lua_next(L, index)) {
        ++entries;
        int key = lua_type(L, -2);
        if (key == LUA_TNUMBER) {
            double n = lua_tonumber(L, -2);
            if (!isfinite(n) || n < 1 || floor(n) != n) fail(L, SHAPE);
            numeric++;
            if (n > maximum) maximum = n;
        } else if (key == LUA_TSTRING) {
            text++;
        } else {
            fail(L, SHAPE);
        }
        lua_pop(L, 1);
    }
    if (numeric && text) fail(L, SHAPE);
    int array = numeric && maximum == (double)numeric;
    if (numeric && !array) fail(L, SHAPE);
    emit(L, array ? CPI_ARRAY : CPI_OBJECT, NULL, 0, 0);
    if (!array) lua_pushnil(L);
    push_table(L, (struct cpi_registry_table_frame){.identity = identity, .index = index, .array = array, .entries = entries});
    return 1;
}

static void generic_value(lua_State *L)
{
    cpi_registry_runtime *r = context(L);
    if (!begin_generic_value(L, -1)) return;
    while (r->table_count) {
        struct cpi_registry_table_frame *table = &r->tables[r->table_count - 1];
        int has_child;
        if (table->array) {
            has_child = table->next < table->entries;
            if (has_child) {
                lua_pushnumber(L, (double)++table->next);
                lua_rawget(L, table->index);
            }
        } else if ((has_child = lua_next(L, table->index))) {
            size_t length;
            const char *key = lua_tolstring(L, -2, &length);
            emit(L, CPI_KEY, key, length, 0);
        }
        if (has_child) {
            if (!begin_generic_value(L, -1)) lua_pop(L, 1);
            continue;
        }
        emit(L, CPI_END, NULL, 0, 0);
        if (--r->table_count) lua_pop(L, 1);
    }
}

static int traverse(lua_State *L)
{
    cpi_registry_runtime *r = lua_touserdata(L, 1);
    lua_State *thread = r->thread;
    if (lua_gettop(thread) != 1) fail(L, SHAPE);
    lua_pushvalue(thread, 1);
    lua_xmove(thread, L, 1);
    if (r->generic) generic_value(L);
    else value(L, -1, CONFIG, 0);
    return 0;
}

int cpi_registry_eval(cpi_registry_runtime *r, const char *source, size_t length)
{
    r->bytecode = cpi_registry_compile(r, source, length, &r->bytecode_length);
    if (!r->bytecode) return OOM;
    lua_State *L = lua_newstate(allocate, r);
    r->state = L;
    if (!L) {
        r->alloc(r->allocator, (void *)r->bytecode, r->bytecode_length, 0);
        r->bytecode = NULL;
        return r->error ? r->error : OOM;
    }
    lua_callbacks(L)->userdata = r;
    lua_callbacks(L)->interrupt = interrupt;
    int status = lua_cpcall(L, initialize, r);
    r->alloc(r->allocator, (void *)r->bytecode, r->bytecode_length, 0);
    r->bytecode = NULL;
    if (!status) status = lua_resume(r->thread, NULL, 0);
    if (!status) status = lua_cpcall(L, traverse, r);
    if (r->error) return r->error;
    return status == LUA_OK ? 0 : status == LUA_ERRMEM ? OOM : RUNTIME;
}

void cpi_registry_close(cpi_registry_runtime *r)
{
    if (r->state) lua_close(r->state);
    if (r->ancestors) r->alloc(r->allocator, r->ancestors, r->ancestor_capacity * sizeof(void *), 0);
    if (r->tables) r->alloc(r->allocator, r->tables, r->table_capacity * sizeof(*r->tables), 0);
    r->ancestors = NULL;
    r->tables = NULL;
    r->state = NULL;
}
