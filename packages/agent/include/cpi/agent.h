#ifndef CPI_AGENT_H
#define CPI_AGENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CPI_AGENT_ABI_VERSION 2u

/* Serialize calls through one driver. Synchronize any handoff between threads. */
typedef struct cpi_agent cpi_agent;
typedef struct cpi_agent_registry cpi_agent_registry;

typedef struct {
    const uint8_t *ptr;
    size_t len;
} cpi_agent_bytes;

typedef int32_t cpi_agent_status;
enum {
    CPI_AGENT_OK = 0,
    CPI_AGENT_NO_EVENT = 1,
    CPI_AGENT_INVALID_ARGUMENT = 2,
    CPI_AGENT_ABI_MISMATCH = 3,
    CPI_AGENT_INVALID_STATE = 4,
    CPI_AGENT_INVALID_JSON = 5,
    CPI_AGENT_INVALID_EXTENSION = 6,
    CPI_AGENT_DUPLICATE_CAPABILITY = 7,
    CPI_AGENT_REQUEST_CONFLICT = 8,
    CPI_AGENT_LIMIT_EXCEEDED = 9,
    CPI_AGENT_OUT_OF_MEMORY = 10,
    CPI_AGENT_STALE_OPERATION = 11,
    CPI_AGENT_STALE_EVENT = 12,
    CPI_AGENT_JOURNAL_LOCKED = 13,
    CPI_AGENT_STORAGE_ERROR = 14,
    CPI_AGENT_CONCURRENCY_UNAVAILABLE = 15
};

typedef struct {
    uint32_t struct_size;
    uint32_t abi_version;
    cpi_agent_bytes session_id;
    cpi_agent_bytes workspace;
    cpi_agent_bytes journal_uri;
    cpi_agent_bytes options_json;
} cpi_agent_config;

typedef uint32_t cpi_agent_command_kind;
enum {
    CPI_AGENT_COMMAND_INPUT = 1,
    CPI_AGENT_COMMAND_STEER = 2,
    CPI_AGENT_COMMAND_CANCEL = 3,
    CPI_AGENT_COMMAND_LUA = 4,
    CPI_AGENT_COMMAND_CLOSE = 5
};

typedef struct {
    uint32_t struct_size;
    cpi_agent_command_kind kind;
    cpi_agent_bytes request_id;
    cpi_agent_bytes payload_json;
} cpi_agent_command;

typedef uint32_t cpi_agent_disposition;
enum {
    CPI_AGENT_RUNNABLE = 1,
    CPI_AGENT_WAITING = 2,
    CPI_AGENT_CLOSED = 3,
    CPI_AGENT_FAILED = 4
};

typedef struct {
    uint32_t struct_size;
    cpi_agent_disposition disposition;
    uint64_t wake_at_unix_ms;
} cpi_agent_schedule;

typedef uint32_t cpi_agent_event_kind;
enum {
    CPI_AGENT_EVENT_READY = 1,
    CPI_AGENT_EVENT_IO_REQUEST = 2,
    CPI_AGENT_EVENT_IO_CANCEL = 3,
    CPI_AGENT_EVENT_COMMAND_COMMITTED = 4,
    CPI_AGENT_EVENT_COMMAND_FINISHED = 5,
    CPI_AGENT_EVENT_CTX_COMMITTED = 6,
    CPI_AGENT_EVENT_TOOL_STARTED = 7,
    CPI_AGENT_EVENT_TOOL_FINISHED = 8,
    CPI_AGENT_EVENT_PROGRESS = 9,
    CPI_AGENT_EVENT_FAULT = 10,
    CPI_AGENT_EVENT_CAPABILITIES_COMMITTED = 11
};

typedef struct {
    uint32_t struct_size;
    cpi_agent_event_kind kind;
    uint64_t lease_id;
    uint64_t operation_id;
    uint64_t sequence;
    cpi_agent_bytes request_id;
    cpi_agent_bytes method;
    cpi_agent_bytes json;
} cpi_agent_event;

typedef uint32_t cpi_agent_io_kind;
enum {
    CPI_AGENT_IO_META = 1,
    CPI_AGENT_IO_DATA = 2,
    CPI_AGENT_IO_DONE = 3,
    CPI_AGENT_IO_ERROR = 4,
    CPI_AGENT_IO_CANCELLED = 5
};

uint32_t cpi_agent_abi_version(void);

cpi_agent_status cpi_agent_registry_create(uint32_t abi_version, cpi_agent_registry **out_registry);

/* Source must return one capability descriptor; registration never invokes execute. */
cpi_agent_status cpi_agent_registry_add_lua(cpi_agent_registry *registry,
                                            cpi_agent_bytes source_name,
                                            cpi_agent_bytes source);

void cpi_agent_registry_destroy(cpi_agent_registry *registry);

/* Initial capabilities seed new sessions only. Open locks and recovers storage. */
cpi_agent_status cpi_agent_open(const cpi_agent_registry *initial_capabilities,
                                const cpi_agent_config *config,
                                cpi_agent **out_agent);

/* OK means queued in memory; COMMAND_COMMITTED confirms durable admission. */
cpi_agent_status cpi_agent_send(cpi_agent *agent, const cpi_agent_command *command);

/* These calls queue capability registration changes. The native actor validates and applies them. */
cpi_agent_status cpi_agent_register_lua(cpi_agent *agent,
                                        cpi_agent_bytes request_id,
                                        cpi_agent_bytes source_name,
                                        cpi_agent_bytes source);

cpi_agent_status
cpi_agent_unregister_capability(cpi_agent *agent, cpi_agent_bytes request_id, cpi_agent_bytes name);

/* Synchronization barrier and status query. Positive budgets are reserved in ABI v2. */
cpi_agent_status cpi_agent_run(cpi_agent *agent,
                               uint64_t now_unix_ms,
                               uint32_t max_transitions,
                               uint32_t max_lua_instructions,
                               cpi_agent_schedule *out_schedule);

/* On OK, the caller owns one event lease. Spans stay immutable and valid until release. */
cpi_agent_status cpi_agent_next_event(cpi_agent *agent, cpi_agent_event *out_event);

/* Only the driver releases a lease, after all readers have stopped using it. */
cpi_agent_status cpi_agent_event_release(cpi_agent *agent, uint64_t lease_id);

/* OK copies data once into worker storage; any error accepts no input. */
cpi_agent_status cpi_agent_io_feed(cpi_agent *agent,
                                   uint64_t operation_id,
                                   cpi_agent_io_kind kind,
                                   cpi_agent_bytes data);

/* Stop and settle host operations and release event leases before destroy. Destroy joins. */
void cpi_agent_destroy(cpi_agent *agent);

#ifdef __cplusplus
}
#endif

#endif
