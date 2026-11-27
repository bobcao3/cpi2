#ifndef CPI_AGENT_LUAVM_BRIDGE_H
#define CPI_AGENT_LUAVM_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct cpi_luavm cpi_luavm;
typedef struct cpi_luavm_owner cpi_luavm_owner;
typedef struct {
    void *context;
    const void *vtable;
    void *ledger;
    void *(*reallocate)(void *, const void *, void *, void *, size_t, size_t, size_t, int *);
} cpi_luavm_memory;
typedef struct { const unsigned char *ptr; size_t len; } cpi_luavm_span;
typedef struct { cpi_luavm_span name, source; int registered; } cpi_luavm_tool;
typedef struct { int tag; cpi_luavm_span a, b, c, d, e; } cpi_luavm_step;

int cpi_luavm_initialize_runtime(void);
int cpi_luavm_open(cpi_luavm_owner **out, cpi_luavm_span bootstrap, cpi_luavm_memory memory);
void cpi_luavm_close(cpi_luavm_owner *heap);
void cpi_luavm_counts(uint64_t *values);
size_t cpi_luavm_used(cpi_luavm_owner *heap);
uint64_t cpi_luavm_compilations(void);
int cpi_luavm_begin(cpi_luavm_owner *heap, cpi_luavm **out, cpi_luavm_span ctx,
                  const cpi_luavm_tool *tools, size_t count, cpi_luavm_span source,
                  int describe, cpi_luavm_span input, cpi_luavm_span environment);
cpi_luavm_step cpi_luavm_advance(cpi_luavm *vm, uint32_t budget, const cpi_luavm_span *reply, int failed);
void cpi_luavm_destroy(cpi_luavm *vm);
cpi_luavm_span cpi_luavm_metadata(cpi_luavm *vm);
int cpi_luavm_retain_tool(cpi_luavm *vm, int *root);
void cpi_luavm_release_tool(cpi_luavm_owner *heap, int root);
char *cpi_luavm_compile(cpi_luavm_memory memory, int *failure, const char *source, size_t length, size_t *size);
int cpi_luavm_number(const char *source, size_t length, double *value);

#ifdef __cplusplus
}
#endif
#endif
