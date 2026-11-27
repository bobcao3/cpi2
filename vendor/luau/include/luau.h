#ifndef CPI_LUAU_H
#define CPI_LUAU_H

#if defined(LUA_USE_LONGJMP) && LUA_USE_LONGJMP != 1
#error "This Luau build requires LUA_USE_LONGJMP=1"
#endif
#ifndef LUA_USE_LONGJMP
#define LUA_USE_LONGJMP 1
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include <lua.h>
#include <luacode.h>
#include <lualib.h>

#ifdef __cplusplus
}
#endif

#endif
