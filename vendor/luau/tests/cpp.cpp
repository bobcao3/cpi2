#include <cstdlib>
#include <luau.h>

int main()
{
    lua_State *state = luaL_newstate();
    if (!state)
        return 1;
    lua_close(state);

    const char source[] = "return 13";
    size_t size = 0;
    char *bytecode = luau_compile(source, sizeof(source) - 1, nullptr, &size);
    if (!bytecode)
        return 1;
    const bool valid = size > 0 && bytecode[0] != 0;
    std::free(bytecode);
    return valid ? 0 : 1;
}
