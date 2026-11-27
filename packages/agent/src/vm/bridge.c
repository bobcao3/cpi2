#include "bridge.h"
#include <limits.h>
#include <luau.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct cpi_luavm_owner {
    cpi_luavm_memory memory;
    size_t activations;
    lua_State *main;
    size_t used;
    uint64_t random_seed;
    int factory, sealed, allocation_failure, poisoned;
    char *app_source, *app_code;
    size_t app_source_size, app_code_size;
    cpi_luavm *active;
};

static _Atomic uint64_t heaps_opened, heaps_closed, bootstrap_loads, registrations,
    activations_started, activations_finished;

enum effect_wait { effect_idle, effect_pending, history_pending };

struct cpi_luavm {
    cpi_luavm_owner *heap;
    int root, bindings, tool_root;
    lua_State *main, *thread;
    char *compiled;
    size_t compiled_size;
    uint64_t budget, random_state;
    int ready, sealed, violation, terminal, error_kind;
    enum effect_wait waiting;
    cpi_luavm_span bootstrap, ctx, source, reply, input, environment;
    const cpi_luavm_tool *tools;
    size_t count;
    int registration, application, mutable, policy, controller, preserve_input, reply_failed;
    char *diagnostic;
    size_t diagnostic_size;
};

static void *allocate(void *ud, void *ptr, size_t old, size_t size)
{
    cpi_luavm_owner *v = ud;
    if (!ptr) old = 0;
    void *next = v->memory.reallocate(v->memory.context, v->memory.vtable, v->memory.ledger,
                                      ptr, old, size, _Alignof(max_align_t), &v->allocation_failure);
    if ((next || !size) && ptr != v) v->used = v->used - old + size;
    return next;
}

static cpi_luavm *owner(lua_State *L)
{
    return ((cpi_luavm_owner *)lua_callbacks(L)->userdata)->active;
}
static void interrupt(lua_State *L, int gc)
{
    cpi_luavm *v = owner(L);
    if (v && gc < 0 && v->sealed) {
        if (v->budget)
            --v->budget;
        if (!v->budget)
            lua_break(L);
    }
}

static cpi_luavm_span span(lua_State *L, int index)
{
    cpi_luavm_span s = {NULL, 0};
    if (lua_type(L, index) == LUA_TSTRING)
        s.ptr = (const unsigned char *)lua_tolstring(L, index, &s.len);
    return s;
}

static int is_history(cpi_luavm_span tool, cpi_luavm_span endpoint)
{
    static const char application[] = "__application", history[] = "__history";
    return tool.len == sizeof(application) - 1 && endpoint.len == sizeof(history) - 1 &&
           memcmp(tool.ptr, application, tool.len) == 0 && memcmp(endpoint.ptr, history, endpoint.len) == 0;
}

static char *diagnostic_buffer(cpi_luavm *v, size_t size)
{
    if (v->diagnostic)
        allocate(v->heap, v->diagnostic, v->diagnostic_size, 0);
    v->diagnostic = size ? allocate(v->heap, NULL, 0, size) : NULL;
    v->diagnostic_size = v->diagnostic ? size : 0;
    return v->diagnostic;
}

static void diagnostic(cpi_luavm *v, lua_State *L, const char *prefix)
{
    cpi_luavm_span s = span(L, -1);
    if (!s.ptr) {
        const char *type = lua_typename(L, lua_type(L, -1));
        size_t size = strlen(prefix) + strlen(type) + sizeof("non-string Lua error ()");
        char *output = diagnostic_buffer(v, size);
        if (output) snprintf(output, size, "%snon-string Lua error (%s)", prefix, type);
        return;
    }
    char *output = NULL;
    const char *hex = "0123456789abcdef";
    for (int pass = 0; pass < 2; ++pass) {
        size_t used = strlen(prefix);
        if (output) memcpy(output, prefix, used);
        for (size_t i = 0; i < s.len;) {
            unsigned char b = s.ptr[i];
            size_t n = b < 128 ? 1 : b >= 194 && b <= 223 ? 2 : b >= 224 && b <= 239 ? 3 : b >= 240 && b <= 244 ? 4 : 0;
            int valid = n && n <= s.len - i;
            for (size_t j = 1; valid && j < n; ++j)
                valid = (s.ptr[i + j] & 192) == 128;
            if (valid && n >= 3) {
                unsigned char c = s.ptr[i + 1];
                if ((b == 224 && c < 160) || (b == 237 && c >= 160) || (b == 240 && c < 144) || (b == 244 && c >= 144))
                    valid = 0;
            }
            if (used > SIZE_MAX - 5) {
                diagnostic_buffer(v, 0);
                return;
            }
            if (!b || !valid) {
                if (output) {
                    output[used] = '\\';
                    output[used + 1] = 'x';
                    output[used + 2] = hex[b >> 4];
                    output[used + 3] = hex[b & 15];
                }
                used += 4;
                ++i;
            } else {
                if (output) memcpy(output + used, s.ptr + i, n);
                used += n;
                i += n;
            }
        }
        if (output) output[used] = 0;
        else {
            output = diagnostic_buffer(v, used + 1);
            if (!output) return;
        }
    }
}

static int guard(lua_State *L)
{
    cpi_luavm *v = owner(L);
    if (!v->ready) {
        v->violation = 1;
        luaL_error(L, "host effects are forbidden during module loading");
    }
    return 0;
}

static int effect(lua_State *L)
{
    guard(L);
    if (lua_gettop(L) != 5)
        luaL_error(L, "invalid native effect");
    for (int i = 1; i <= 5; ++i) {
        if (lua_type(L, i) != LUA_TSTRING)
            luaL_error(L, "invalid native effect");
    }
    return lua_yield(L, 5);
}

static int ready(lua_State *L)
{
    cpi_luavm *v = owner(L);
    if (v->ready || v->violation)
        luaL_error(L, "invalid module bootstrap");
    v->ready = 1;
    return lua_yield(L, 0);
}

static int number(lua_State *L)
{
    size_t size = 0;
    const char *text = luaL_checklstring(L, 1, &size);
    double value = 0;
    if (!cpi_luavm_number(text, size, &value))
        luaL_error(L, "JSON number is outside finite binary64 range");
    lua_pushnumber(L, value);
    return 1;
}

static int json_special(lua_State *L)
{
    size_t size;
    const unsigned char *text = (const unsigned char *)luaL_checklstring(L, 1, &size);
    int start = luaL_checkinteger(L, 2);
    luaL_argcheck(L, start > 0, 2, "invalid JSON scan position");
    for (size_t i = (size_t)start - 1; i < size; ++i) {
        unsigned char byte = text[i];
        if (byte < 32 || byte == '"' || byte == '\\') {
            lua_pushnumber(L, (double)(i + 1));
            return 1;
        }
    }
    return 0;
}

static int seal(lua_State *L)
{
    cpi_luavm *v = owner(L);
    if (v->sealed)
        luaL_error(L, "sandbox already sealed");
    v->sealed = 1;
    v->error_kind = 0;
    if (v->heap->sealed)
        return 0;
    lua_getglobal(L, "string");
    lua_setreadonly(L, -1, 0);
    const char *names[] = {"find", "match", "gmatch", "gsub", NULL};
    for (const char **p = names; *p; ++p) {
        lua_pushnil(L);
        lua_setfield(L, -2, *p);
    }
    lua_pushvalue(L, 1);
    lua_setfield(L, -2, "find");
    lua_setreadonly(L, -1, 1);
    v->heap->sealed = 1;
    return 0;
}

static void load(lua_State *L, cpi_luavm_span source, const char *name, int kind)
{
    cpi_luavm *v = owner(L);
    cpi_luavm_owner *heap = v->heap;
    const int application = v->application && source.ptr == v->source.ptr &&
                            source.len == v->source.len && source.len > 0 && source.len <= 256 * 1024;
    if (application && heap->app_source_size == source.len &&
        !memcmp(source.ptr, heap->app_source, source.len)) {
        int status = luau_load(L, name, heap->app_code, heap->app_code_size, 0);
        if (status != LUA_OK) {
            v->error_kind = status == LUA_ERRMEM ? 2 : kind;
            lua_error(L);
        }
        return;
    }
    size_t length = 0;
    char *code = cpi_luavm_compile(heap->memory, &heap->allocation_failure,
                                  (const char *)source.ptr, source.len, &length);
    if (!code) {
        v->error_kind = heap->allocation_failure ? heap->allocation_failure : 1;
        luaL_error(L, "compiler allocation failed");
    }
    v->compiled = code;
    v->compiled_size = length;
    heap->used += length;
    int status = luau_load(L, name, code, length, 0);
    if (status == LUA_OK && !strcmp(name, "=agent-bootstrap"))
        atomic_fetch_add(&bootstrap_loads, 1);
    if (status == LUA_OK && application && length <= 256 * 1024) {
        // Retain bytecode only. Every invocation still loads a fresh closure and environment.
        int prior_failure = heap->allocation_failure;
        char *key = allocate(heap, NULL, 0, source.len);
        if (key) {
            memcpy(key, source.ptr, source.len);
            if (heap->app_source) allocate(heap, heap->app_source, heap->app_source_size, 0);
            if (heap->app_code) allocate(heap, heap->app_code, heap->app_code_size, 0);
            heap->app_source = key;
            heap->app_source_size = source.len;
            heap->app_code = code;
            heap->app_code_size = length;
            code = NULL;
        }
        heap->allocation_failure = prior_failure;
    }
    if (code) allocate(heap, code, length, 0);
    v->compiled = NULL;
    if (status != LUA_OK) {
        v->error_kind = status == LUA_ERRMEM ? 2 : kind;
        lua_error(L);
    }
}

static int compile_inside(lua_State *L)
{
    cpi_luavm *v = owner(L);
    size_t length;
    const char *source = luaL_checklstring(L, 1, &length);
    if (!v->application)
        luaL_error(L, "application compilation is unavailable");
    load(L, (cpi_luavm_span){(const unsigned char *)source, length}, "=application-eval", 5);
    return 1;
}

// PCG and interval semantics match the pinned Luau VM/src/lmathlib.cpp.
static uint32_t random_next(uint64_t *state)
{
    uint64_t old = *state;
    *state = old * 6364136223846793005ULL + 105;
    uint32_t bits = (uint32_t)(((old >> 18) ^ old) >> 27);
    uint32_t rotate = (uint32_t)(old >> 59);
    return (bits >> rotate) | (bits << ((-rotate) & 31));
}
static void random_seed(uint64_t *state, uint64_t seed)
{
    *state = 0;
    random_next(state);
    *state += seed;
    random_next(state);
}
static int invocation_randomseed(lua_State *L)
{
    random_seed(&owner(L)->random_state, (uint64_t)luaL_checkinteger(L, 1));
    return 0;
}
static int invocation_random(lua_State *L)
{
    uint64_t *state = &owner(L)->random_state;
    switch (lua_gettop(L)) {
    case 0: {
        uint32_t low = random_next(state), high = random_next(state);
        lua_pushnumber(L, ldexp((double)(low | ((uint64_t)high << 32)), -64));
        break;
    }
    case 1: {
        int upper = luaL_checkinteger(L, 1);
        luaL_argcheck(L, upper >= 1, 1, "interval is empty");
        uint64_t value = (uint64_t)upper * random_next(state);
        lua_pushinteger(L, (int)(1 + (value >> 32)));
        break;
    }
    case 2: {
        int lower = luaL_checkinteger(L, 1), upper = luaL_checkinteger(L, 2);
        luaL_argcheck(L, lower <= upper, 2, "interval is empty");
        uint32_t width = (uint32_t)upper - (uint32_t)lower;
        luaL_argcheck(L, width < UINT_MAX, 2, "interval is too large");
        uint64_t value = (uint64_t)(width + 1) * random_next(state);
        lua_pushinteger(L, (int)(lower + (value >> 32)));
        break;
    }
    default:
        luaL_error(L, "wrong number of arguments");
    }
    return 1;
}

static int current(lua_State *L)
{
    cpi_luavm *v = owner(L);
    if (!v->ready || v->bindings < 0)
        lua_pushnil(L);
    else
        lua_getref(L, v->bindings);
    return 1;
}
static int module_index(lua_State *L)
{
    cpi_luavm *v = owner(L);
    cpi_luavm_span key = span(L, 2);
    if (key.len == 5 && !memcmp(key.ptr, "tools", 5)) {
        if (!v->ready || v->bindings < 0)
            lua_pushnil(L);
        else {
            lua_getref(L, v->bindings);
            lua_getfield(L, -1, "tools");
        }
    } else {
        lua_pushvalue(L, 2);
        lua_rawget(L, lua_upvalueindex(1));
    }
    return 1;
}
static int module_indexer(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushvalue(L, 1);
    lua_pushcclosure(L, module_index, "module.index", 1);
    return 1;
}

static int bind(lua_State *L)
{
    cpi_luavm *v = owner(L);
    if (v->bindings >= 0 || v->registration)
        luaL_error(L, "invalid invocation bindings");
    v->bindings = lua_ref(L, 1);
    return 0;
}
static int registration(lua_State *L)
{
    atomic_fetch_add(&registrations, 1);
    (void)L;
    return 0;
}

static int prepare(lua_State *L)
{
    cpi_luavm *v = lua_touserdata(L, 1);
    v->thread = lua_newthread(L);
    v->root = lua_ref(L, -1);
    lua_pop(L, 1);
    lua_getref(L, v->heap->factory);
    lua_pushlstring(L, (const char *)v->ctx.ptr, v->ctx.len);
    lua_createtable(L, (int)v->count, 0);
    for (size_t i = 0; i < v->count; ++i) {
        lua_createtable(L, 0, 2);
        lua_pushlstring(L, (const char *)v->tools[i].name.ptr, v->tools[i].name.len);
        lua_setfield(L, -2, "name");
        if (v->tools[i].registered >= 0) {
            lua_getref(L, v->tools[i].registered);
            lua_setfield(L, -2, "version");
        } else {
            load(L, v->tools[i].source, "=tool-module", 3);
            lua_setfield(L, -2, "chunk");
        }
        lua_rawseti(L, -2, (int)i + 1);
    }
    if (v->registration)
        lua_pushnil(L);
    else
        load(L, v->source, v->policy ? "=authorization" : "=invocation", 5);
    lua_pushboolean(L, v->registration);
    lua_createtable(L, 0, 10);
    lua_pushlstring(L, (const char *)v->input.ptr, v->input.len);
    lua_setfield(L, -2, "input");
    lua_pushlstring(L, (const char *)v->environment.ptr, v->environment.len);
    lua_setfield(L, -2, "environment");
    lua_pushboolean(L, v->controller);
    lua_setfield(L, -2, "controller");
    lua_pushboolean(L, v->application);
    lua_setfield(L, -2, "application");
    lua_pushboolean(L, v->preserve_input);
    lua_setfield(L, -2, "preserveInput");
    lua_pushboolean(L, v->mutable);
    lua_setfield(L, -2, "mutable");
    lua_pushcfunction(L, invocation_random, "math.random");
    lua_setfield(L, -2, "random");
    lua_pushcfunction(L, invocation_randomseed, "math.randomseed");
    lua_setfield(L, -2, "randomseed");
    lua_pushcfunction(L, module_indexer, "module.indexer");
    lua_setfield(L, -2, "moduleIndex");
    lua_pushcfunction(L, current, "invocation.current");
    lua_setfield(L, -2, "current");
    lua_pushcfunction(L, bind, "invocation.bind");
    lua_setfield(L, -2, "bind");
    lua_pushcfunction(L, registration, "tool.registration");
    lua_setfield(L, -2, "registration");
    lua_pushcfunction(L, compile_inside, "application.compile");
    lua_setfield(L, -2, "compile");
    lua_pushcfunction(L, effect, "host.call");
    lua_setfield(L, -2, "call");
    lua_pushcfunction(L, ready, "bootstrap.ready");
    lua_setfield(L, -2, "ready");
    lua_pushcfunction(L, seal, "bootstrap.seal");
    lua_setfield(L, -2, "seal");
    lua_pushcfunction(L, guard, "bootstrap.guard");
    lua_setfield(L, -2, "guard");
    lua_pushcfunction(L, number, "json.number");
    lua_setfield(L, -2, "number");
    lua_pushcfunction(L, json_special, "json.special");
    lua_setfield(L, -2, "jsonSpecial");
    lua_xmove(L, v->thread, 6);
    return 0;
}

int cpi_luavm_begin(cpi_luavm_owner *heap,
                    cpi_luavm **out,
                    cpi_luavm_span ctx,
                    const cpi_luavm_tool *tools,
                    size_t count,
                    cpi_luavm_span source,
                    int describe,
                    cpi_luavm_span input,
                    cpi_luavm_span environment)
{
    *out = NULL;
    if (heap->poisoned) return 6;
    if (count > INT_MAX) return 3;
    heap->allocation_failure = 0;
    cpi_luavm *v = allocate(heap, NULL, 0, sizeof(*v));
    if (!v) return heap->allocation_failure;
    memset(v, 0, sizeof(*v));
    heap->activations += 1;
    atomic_fetch_add(&activations_started, 1);
    v->heap = heap;
    v->root = v->bindings = -1;

    v->ctx = ctx;
    v->source = source;
    v->input = input;
    v->environment = environment;
    v->tools = tools;
    v->count = count;
    v->registration = describe & 1;
    v->application = !!(describe & 2);
    v->mutable = !!(describe & 4);
    v->policy = !!(describe & 8);
    v->controller = !!(describe & 16);
    v->preserve_input = !!(describe & 32);
    describe = v->registration;
    random_seed(&v->random_state, ++heap->random_seed);
    v->budget = 100001;
    v->main = heap->main;
    heap->active = v;
    heap->allocation_failure = 0;

    int status = lua_cpcall(v->main, prepare, v);
    if (status == LUA_OK) {
        v->error_kind = 4;
        status = lua_resume(v->thread, NULL, 5);
    }
    int expected = describe ? LUA_OK : LUA_YIELD;
    if (status != expected || v->violation || (!describe && !v->ready)) {
        int code = heap->allocation_failure                      ? heap->allocation_failure
                   : status == LUA_BREAK || status == LUA_ERRMEM ? 2
                   : v->error_kind                               ? v->error_kind
                                                                 : 3;
        if (v->sealed && !heap->sealed)
            heap->poisoned = 1;
        cpi_luavm_destroy(v);
        return code;
    }
    heap->active = NULL;
    lua_settop(heap->main, 0);
    v->tools = NULL;
    v->count = 0;
    v->bootstrap = v->ctx = v->source = v->input = v->environment = (cpi_luavm_span){NULL, 0};
    if (describe)
        v->terminal = 1;
    *out = v;
    return 0;
}

static int push_reply(lua_State *L)
{
    cpi_luavm *v = lua_touserdata(L, 1);
    lua_pushlstring(L, (const char *)v->reply.ptr, v->reply.len);
    lua_pushboolean(L, v->reply_failed);
    lua_xmove(L, v->thread, 2);
    return 0;
}

static cpi_luavm_step failure(cpi_luavm *v, const char *message)
{
    if (message) {
        size_t size = strlen(message) + 1;
        char *output = diagnostic_buffer(v, size);
        if (output) memcpy(output, message, size);
    }
    v->terminal = 1;
    cpi_luavm_step result = {0};
    result.tag = 3;
    const char *text = v->diagnostic ? v->diagnostic : "Lua diagnostic allocation failed";
    result.a = (cpi_luavm_span){(const unsigned char *)text, strlen(text)};
    return result;
}

cpi_luavm_step
cpi_luavm_advance(cpi_luavm *v, uint32_t budget, const cpi_luavm_span *reply, int failed)
{
    v->heap->active = v;
    cpi_luavm_step result = {0};
    if (v->terminal)
        return failure(v, "invocation already finished");
    if (!!reply != !!v->waiting)
        return failure(v, "reply must be supplied exactly once after an effect");
    if (!budget && !reply)
        return result;
    int nargs = 0;
    if (reply) {
        lua_settop(v->thread, 0);
        if (v->waiting != history_pending)
            lua_gc(v->main, LUA_GCCOLLECT, 0);
        v->reply = *reply;
        v->reply_failed = failed;
        int status = lua_cpcall(v->main, push_reply, v);
        if (status == LUA_ERRMEM && v->waiting == history_pending) {
            lua_settop(v->main, 0);
            lua_gc(v->main, LUA_GCCOLLECT, 0);
            status = lua_cpcall(v->main, push_reply, v);
        }
        v->reply = (cpi_luavm_span){NULL, 0};
        if (status != LUA_OK) {
            diagnostic(v, v->main, "reply allocation: ");
            lua_settop(v->main, 0);
            return failure(v, NULL);
        }
        nargs = 2;
        v->waiting = effect_idle;
    }
    v->budget = (uint64_t)budget + 1;
    int status = lua_resume(v->thread, NULL, nargs);
    if (status == LUA_BREAK)
        return result;
    if (status == LUA_YIELD && lua_gettop(v->thread) == 5) {
        result.tag = 1;
        result.a = span(v->thread, 1);
        result.b = span(v->thread, 2);
        result.c = span(v->thread, 3);
        result.d = span(v->thread, 4);
        result.e = span(v->thread, 5);
        // Walking history retains entries in the invocation. Collecting the
        // whole live graph on each read would revisit every prior entry.
        v->waiting = v->application && is_history(result.a, result.b) ? history_pending : effect_pending;
        if (v->waiting == effect_pending)
            lua_gc(v->main, LUA_GCCOLLECT, 0);
        return result;
    }
    if (status == LUA_OK && lua_gettop(v->thread) == 4 && lua_toboolean(v->thread, 4)) {
        lua_pushvalue(v->thread, 1);
        diagnostic(v, v->thread, "Lua runtime: ");
        result = failure(v, NULL);
        result.e = span(v->thread, 3);
        return result;
    }
    if (status == LUA_OK && lua_gettop(v->thread) == 3) {
        result.tag = 2;
        result.a = span(v->thread, 1);
        result.b = span(v->thread, 2);
        result.e = span(v->thread, 3);
        v->terminal = 1;
        return result;
    }
    diagnostic(v, v->thread, "Lua runtime: ");
    return failure(v, NULL);
}

cpi_luavm_span cpi_luavm_metadata(cpi_luavm *v) { return span(v->thread, 1); }
static int retain_tool(lua_State *L)
{
    cpi_luavm *v = lua_touserdata(L, 1);
    lua_pushvalue(v->thread, 2);
    lua_xmove(v->thread, L, 1);
    v->tool_root = lua_ref(L, -1);
    return 0;
}
int cpi_luavm_retain_tool(cpi_luavm *v, int *root)
{
    v->tool_root = -1;
    int status = lua_cpcall(v->main, retain_tool, v);
    lua_settop(v->main, 0);
    *root = v->tool_root;
    return status == LUA_OK ? 0 : 2;
}
void cpi_luavm_release_tool(cpi_luavm_owner *heap, int root)
{
    lua_unref(heap->main, root);
    heap->active = NULL;
    lua_gc(heap->main, LUA_GCCOLLECT, 0);
}
void cpi_luavm_destroy(cpi_luavm *v)
{
    if (!v)
        return;
    if (v->compiled) {
        allocate(v->heap, v->compiled, v->compiled_size, 0);
    }
    diagnostic_buffer(v, 0);
    if (v->root >= 0)
        lua_unref(v->main, v->root);
    if (v->bindings >= 0)
        lua_unref(v->main, v->bindings);
    lua_settop(v->main, 0);
    v->heap->active = NULL;
    lua_gc(v->main, LUA_GCCOLLECT, 0);
    v->heap->activations -= 1;
    atomic_fetch_add(&activations_finished, 1);
    allocate(v->heap, v, sizeof(*v), 0);
}

static int initialize(lua_State *L)
{
    cpi_luavm *v = lua_touserdata(L, 1);
    luaL_openlibs(L);
    v->heap->random_seed =
        lua_encodepointer(L, (uintptr_t)v->heap) ^ (uint64_t)time(NULL) ^ (uint64_t)clock();
    luaL_sandbox(L);
    load(L, v->bootstrap, "=agent-bootstrap", 3);
    lua_call(L, 0, 1);
    v->heap->factory = lua_ref(L, -1);
    return 0;
}

int cpi_luavm_open(cpi_luavm_owner **out, cpi_luavm_span bootstrap, cpi_luavm_memory memory)
{
    *out = NULL;
    if (cpi_luavm_initialize_runtime())
        return 1;
    int failure = 0;
    cpi_luavm_owner *heap = memory.reallocate(memory.context, memory.vtable, memory.ledger,
                                             NULL, 0, sizeof(*heap), _Alignof(max_align_t), &failure);
    if (!heap) return failure;
    memset(heap, 0, sizeof(*heap));
    heap->memory = memory;
    heap->used = sizeof(*heap);
    heap->main = lua_newstate(allocate, heap);
    if (!heap->main) {
        int code = heap->allocation_failure;
        allocate(heap, heap, sizeof(*heap), 0);
        return code ? code : 1;
    }
    atomic_fetch_add(&heaps_opened, 1);
    cpi_luavm initial = {0};
    initial.heap = heap;
    initial.bootstrap = bootstrap;
    heap->active = &initial;
    lua_callbacks(heap->main)->userdata = heap;
    lua_callbacks(heap->main)->interrupt = interrupt;
    int status = lua_cpcall(heap->main, initialize, &initial);
    if (initial.compiled) {
        allocate(heap, initial.compiled, initial.compiled_size, 0);
    }
    if (status != LUA_OK) {
        int code = heap->allocation_failure;
        cpi_luavm_close(heap);
        return code ? code : 3;
    }
    lua_settop(heap->main, 0);
    heap->active = NULL;
    *out = heap;
    return 0;
}

void cpi_luavm_close(cpi_luavm_owner *heap)
{
    if (!heap)
        return;
    lua_close(heap->main);
    if (heap->app_source) allocate(heap, heap->app_source, heap->app_source_size, 0);
    if (heap->app_code) allocate(heap, heap->app_code, heap->app_code_size, 0);
    atomic_fetch_add(&heaps_closed, 1);
    allocate(heap, heap, sizeof(*heap), 0);
}

void cpi_luavm_counts(uint64_t *values)
{
    values[0] = atomic_load(&heaps_opened);
    values[1] = atomic_load(&heaps_closed);
    values[2] = atomic_load(&bootstrap_loads);
    values[3] = cpi_luavm_compilations();
    values[4] = atomic_load(&registrations);
    values[5] = atomic_load(&activations_started);
    values[6] = atomic_load(&activations_finished);
}

size_t cpi_luavm_used(cpi_luavm_owner *heap) { return heap->used; }
