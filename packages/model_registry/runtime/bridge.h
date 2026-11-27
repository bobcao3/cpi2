#ifndef CPI_MODEL_REGISTRY_BRIDGE_H
#define CPI_MODEL_REGISTRY_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void *(*cpi_registry_alloc)(void *, void *, size_t, size_t);
/* Structural events, not an encoded JSON stream. The sink returns an error code;
   only C raises Lua errors, after the Zig callback has returned. */
enum cpi_registry_event { CPI_OBJECT, CPI_ARRAY, CPI_END, CPI_KEY, CPI_STRING, CPI_NUMBER, CPI_BOOL, CPI_NULL };
typedef int (*cpi_registry_sink)(void *, int, const char *, size_t, double);
typedef struct cpi_registry_runtime {
    void *state;
    void *thread;
    cpi_registry_alloc alloc;
    void *allocator;
    size_t used, budget;
    cpi_registry_sink sink;
    void *sink_context;
    const char *bytecode;
    size_t bytecode_length;
    int error;
    const void **ancestors;
    size_t ancestor_capacity;
    struct cpi_registry_table_frame *tables;
    size_t table_count, table_capacity;
    int generic;
} cpi_registry_runtime;

/* The caller closes the runtime even when evaluation fails. */
int cpi_registry_eval(cpi_registry_runtime *, const char *, size_t);

void cpi_registry_close(cpi_registry_runtime *);
char *cpi_registry_compile(cpi_registry_runtime *, const char *, size_t, size_t *);

#ifdef __cplusplus
}
#endif
#endif
