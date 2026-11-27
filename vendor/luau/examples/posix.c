#include <luau.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#define FILE_HANDLE "luau.posix.file"
#define DIRECTORY_HANDLE "luau.posix.directory"
#define READ_LIMIT (1024 * 1024)

typedef struct {
    int descriptor;
} File;

typedef struct {
    DIR *directory;
} Directory;

static int push_error(lua_State *state, int code)
{
    lua_pushnil(state);
    lua_pushstring(state, strerror(code));
    lua_pushinteger(state, code);
    return 3;
}

static const char *check_path(lua_State *state, int index)
{
    size_t length = 0;
    const char *path = luaL_checklstring(state, index, &length);
    if (memchr(path, '\0', length))
        luaL_argerror(state, index, "path contains a NUL byte");
    return path;
}

static void destroy_file(lua_State *state, void *pointer)
{
    (void)state;
    File *file = pointer;
    if (file->descriptor >= 0)
        close(file->descriptor);
}

static void destroy_directory(lua_State *state, void *pointer)
{
    (void)state;
    Directory *directory = pointer;
    if (directory->directory)
        closedir(directory->directory);
}

static int posix_open(lua_State *state)
{
    const char *path = check_path(state, 1);
    int flags = luaL_optinteger(state, 2, O_RDONLY);
    int mode = luaL_optinteger(state, 3, 0666);
    if (mode < 0 || mode > 07777)
        luaL_argerror(state, 3, "mode is out of range");

    File *file = lua_newuserdatadtor(state, sizeof(*file), destroy_file);
    file->descriptor = -1;
    luaL_getmetatable(state, FILE_HANDLE);
    lua_setmetatable(state, -2);

    int descriptor = open(path, flags | O_CLOEXEC, (mode_t)mode);
    if (descriptor < 0)
        return push_error(state, errno);
    file->descriptor = descriptor;
    return 1;
}

static int posix_read(lua_State *state)
{
    File *file = luaL_checkudata(state, 1, FILE_HANDLE);
    double requested = luaL_checknumber(state, 2);
    if (!(requested >= 0 && requested <= READ_LIMIT) || requested != (double)(size_t)requested)
        luaL_argerror(state, 2, "read size is out of range");
    if (file->descriptor < 0)
        return push_error(state, EBADF);

    int top = lua_gettop(state);
    luaL_Buffer buffer;
    char *bytes = luaL_buffinitsize(state, &buffer, (size_t)requested);
    ssize_t count = read(file->descriptor, bytes, (size_t)requested);
    if (count < 0) {
        int code = errno;
        lua_settop(state, top);
        return push_error(state, code);
    }
    luaL_pushresultsize(&buffer, (size_t)count);
    return 1;
}

static int posix_close(lua_State *state)
{
    File *file = luaL_checkudata(state, 1, FILE_HANDLE);
    if (file->descriptor < 0)
        return push_error(state, EBADF);
    int descriptor = file->descriptor;
    file->descriptor = -1;
    if (close(descriptor) < 0)
        return push_error(state, errno);
    lua_pushboolean(state, 1);
    return 1;
}

static int posix_opendir(lua_State *state)
{
    const char *path = check_path(state, 1);
    Directory *directory = lua_newuserdatadtor(state, sizeof(*directory), destroy_directory);
    directory->directory = NULL;
    luaL_getmetatable(state, DIRECTORY_HANDLE);
    lua_setmetatable(state, -2);

    DIR *handle = opendir(path);
    if (!handle)
        return push_error(state, errno);
    directory->directory = handle;
    return 1;
}

static int posix_readdir(lua_State *state)
{
    Directory *directory = luaL_checkudata(state, 1, DIRECTORY_HANDLE);
    if (!directory->directory)
        return push_error(state, EBADF);
    errno = 0;
    struct dirent *entry = readdir(directory->directory);
    if (!entry) {
        int code = errno;
        if (code)
            return push_error(state, code);
        lua_pushnil(state);
        return 1;
    }
    lua_pushstring(state, entry->d_name);
    return 1;
}

static int posix_closedir(lua_State *state)
{
    Directory *directory = luaL_checkudata(state, 1, DIRECTORY_HANDLE);
    if (!directory->directory)
        return push_error(state, EBADF);
    DIR *handle = directory->directory;
    directory->directory = NULL;
    if (closedir(handle) < 0)
        return push_error(state, errno);
    lua_pushboolean(state, 1);
    return 1;
}

int luaopen_posix(lua_State *state)
{
    const char *types[] = {FILE_HANDLE, DIRECTORY_HANDLE};
    for (size_t index = 0; index < sizeof(types) / sizeof(types[0]); ++index) {
        luaL_newmetatable(state, types[index]);
        lua_pushstring(state, types[index]);
        lua_setfield(state, -2, "__metatable");
        lua_setreadonly(state, -1, 1);
        lua_pop(state, 1);
    }

    static const luaL_Reg functions[] = {
        {"open", posix_open},
        {"read", posix_read},
        {"close", posix_close},
        {"opendir", posix_opendir},
        {"readdir", posix_readdir},
        {"closedir", posix_closedir},
        {NULL, NULL},
    };
    lua_newtable(state);
    luaL_register(state, NULL, functions);

#define CONSTANT(name)                                                                             \
    lua_pushinteger(state, name);                                                                  \
    lua_setfield(state, -2, #name)

    CONSTANT(O_RDONLY);
    CONSTANT(O_WRONLY);
    CONSTANT(O_RDWR);
    CONSTANT(O_CREAT);
    CONSTANT(O_EXCL);
    CONSTANT(O_TRUNC);
    CONSTANT(O_APPEND);
    CONSTANT(O_NONBLOCK);
    CONSTANT(O_CLOEXEC);
    CONSTANT(EBADF);
    CONSTANT(ENOENT);
    CONSTANT(EACCES);
    CONSTANT(EINTR);
    CONSTANT(EINVAL);
    lua_pushinteger(state, READ_LIMIT);
    lua_setfield(state, -2, "READ_LIMIT");
#undef CONSTANT
    return 1;
}
