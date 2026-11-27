#include <luau.h>

static int retained(lua_State *state)
{
    lua_pushinteger(state, 73);
    return 1;
}

int luaopen_broken(lua_State *state)
{
    lua_pushcfunction(state, retained, "retained");
    lua_setglobal(state, "retained_from_broken");
    luaL_error(state, "intentional initialization failure");
}

int luaopen_void(lua_State *state)
{
    lua_pushnil(state);
    return 1;
}
