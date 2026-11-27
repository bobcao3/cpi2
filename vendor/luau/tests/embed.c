#include <luau.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                                           \
    do {                                                                                           \
        if (!(condition)) {                                                                        \
            fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition);                        \
            return 1;                                                                              \
        }                                                                                          \
    } while (0)

static int wait_for_host(lua_State *state)
{
    lua_pushinteger(state, luaL_checkinteger(state, 1));
    return lua_yield(state, 1);
}

static int fail_from_host(lua_State *state) { luaL_error(state, "native failure"); }

static lua_State *new_thread(lua_State *main)
{
    lua_State *state = lua_newthread(main);
    luaL_sandboxthread(state);

    lua_newtable(state);
    lua_pushcfunction(state, wait_for_host, "wait");
    lua_setfield(state, -2, "wait");
    lua_pushcfunction(state, fail_from_host, "fail");
    lua_setfield(state, -2, "fail");
    lua_setreadonly(state, -1, 1);
    lua_setglobal(state, "native");
    return state;
}

static int load_source(lua_State *state, const char *source)
{
    size_t size = 0;
    char *bytecode = luau_compile(source, strlen(source), NULL, &size);
    if (!bytecode) {
        return -1;
    }
    int status = luau_load(state, "=embed", bytecode, size, 0);
    free(bytecode);
    return status;
}

int main(void)
{
    lua_State *main = luaL_newstate();
    CHECK(main != NULL);
    luaL_openlibs(main);
    luaL_sandbox(main);

    lua_State *state = new_thread(main);
    CHECK(load_source(state,
                      "local total: number = 11\n"
                      "total += native.wait(7)\n"
                      "return total") == LUA_OK);
    CHECK(lua_resume(state, NULL, 0) == LUA_YIELD);
    CHECK(lua_gettop(state) == 1);
    CHECK(lua_tointeger(state, -1) == 7);
    lua_settop(state, 0);
    lua_pushinteger(state, 29);
    CHECK(lua_resume(state, NULL, 1) == LUA_OK);
    CHECK(lua_gettop(state) == 1);
    CHECK(lua_tointeger(state, -1) == 40);

    state = new_thread(main);
    CHECK(load_source(state, "return native.fail()") == LUA_OK);
    CHECK(lua_resume(state, NULL, 0) == LUA_ERRRUN);
    CHECK(lua_type(state, -1) == LUA_TSTRING);
    CHECK(strstr(lua_tostring(state, -1), "native failure") != NULL);

    state = new_thread(main);
    CHECK(load_source(state, "local =") > 0);
    CHECK(lua_type(state, -1) == LUA_TSTRING);
    CHECK(lua_objlen(state, -1) > 0);

    lua_close(main);
    return 0;
}
