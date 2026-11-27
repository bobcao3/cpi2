#include "bridge.h"
#include <Luau/Common.h>
#include <Luau/Compiler.h>
#include <atomic>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <luau.h>
#include <mutex>
#include <new>

namespace {
struct Scope {
    cpi_luavm_memory memory;
    int *failure;
};
thread_local Scope *current = nullptr;
struct Header {
    cpi_luavm_memory memory;
    void *base;
    size_t size;
};
void *allocate_cpp(size_t size, size_t alignment)
{
    alignment = alignment < alignof(Header) ? alignof(Header) : alignment;
    if (size > std::numeric_limits<size_t>::max() - sizeof(Header) - alignment)
        throw std::bad_alloc();
    size_t total = size + sizeof(Header) + alignment - 1;
    void *base;
    if (current) {
        auto m = current->memory;
        base = m.reallocate(m.context, m.vtable, m.ledger, nullptr, 0, total,
                            alignof(max_align_t), current->failure);
    } else {
        base = std::malloc(total);
    }
    if (!base) throw std::bad_alloc();
    uintptr_t address = (reinterpret_cast<uintptr_t>(base) + sizeof(Header) + alignment - 1) & ~(alignment - 1);
    auto *header = reinterpret_cast<Header *>(address) - 1;
    header->memory = current ? current->memory : cpi_luavm_memory{};
    header->base = base;
    header->size = total;
    return reinterpret_cast<void *>(address);
}
void free_cpp(void *ptr) noexcept
{
    if (!ptr) return;
    auto *header = static_cast<Header *>(ptr) - 1;
    auto m = header->memory;
    if (m.reallocate) {
        int failure = 0;
        m.reallocate(m.context, m.vtable, m.ledger, header->base, header->size, 0, alignof(max_align_t), &failure);
    } else {
        std::free(header->base);
    }
}
struct CompilationScope {
    Scope scope;
    Scope *previous;
    CompilationScope(cpi_luavm_memory memory, int *failure) : scope{memory, failure}, previous(current) { current = &scope; }
    ~CompilationScope() { current = previous; }
};
}

void *operator new(size_t size) { return allocate_cpp(size, alignof(max_align_t)); }
void *operator new[](size_t size) { return allocate_cpp(size, alignof(max_align_t)); }
void *operator new(size_t size, std::align_val_t alignment) { return allocate_cpp(size, size_t(alignment)); }
void *operator new[](size_t size, std::align_val_t alignment) { return allocate_cpp(size, size_t(alignment)); }
void operator delete(void *ptr) noexcept { free_cpp(ptr); }
void operator delete[](void *ptr) noexcept { free_cpp(ptr); }
void operator delete(void *ptr, size_t) noexcept { free_cpp(ptr); }
void operator delete[](void *ptr, size_t) noexcept { free_cpp(ptr); }
void operator delete(void *ptr, std::align_val_t) noexcept { free_cpp(ptr); }
void operator delete[](void *ptr, std::align_val_t) noexcept { free_cpp(ptr); }
void operator delete(void *ptr, size_t, std::align_val_t) noexcept { free_cpp(ptr); }
void operator delete[](void *ptr, size_t, std::align_val_t) noexcept { free_cpp(ptr); }

LUAU_DYNAMIC_FASTFLAG(LuauGcHeapShrinkFix)

extern "C" int cpi_luavm_initialize_runtime(void)
{
    try {
        static std::once_flag initialized;
        std::call_once(initialized, [] { DFFlag::LuauGcHeapShrinkFix.value = true; });
        return 0;
    } catch (...) {
        return 1;
    }
}

static std::atomic<uint64_t> compilations{0};
extern "C" uint64_t cpi_luavm_compilations(void) { return compilations.load(); }

extern "C" char *cpi_luavm_compile(cpi_luavm_memory memory, int *failure, const char *source, size_t length, size_t *size)
{
    CompilationScope scope(memory, failure);
    *size = 0;
    try {
        Luau::CompileOptions options = {};
        options.optimizationLevel = 0;
        options.debugLevel = 1;
        compilations.fetch_add(1);
        std::string code = Luau::compile(std::string(source, length), options);
        void *output = memory.reallocate(memory.context, memory.vtable, memory.ledger, nullptr, 0,
                                         code.size(), alignof(max_align_t), failure);
        if (!output) return nullptr;
        std::memcpy(output, code.data(), code.size());
        *size = code.size();
        return static_cast<char *>(output);
    } catch (...) {
        *size = 0;
        return nullptr;
    }
}

extern "C" int cpi_luavm_number(const char *source, size_t length, double *value)
{
    auto result = std::from_chars(source, source + length, *value);
    return result.ec == std::errc{} && result.ptr == source + length && std::isfinite(*value);
}
