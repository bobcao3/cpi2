#include <cpi/agent.h>

#define SOURCE_NAME(text) ((cpi_agent_bytes){(const uint8_t *)(text), sizeof(text) - 1})

cpi_agent_status register_initial_capabilities(cpi_agent_bytes read_source,
                                        cpi_agent_bytes bash_source,
                                        cpi_agent_registry **out_registry)
{
    cpi_agent_registry *registry = NULL;
    *out_registry = NULL;

    cpi_agent_status status = cpi_agent_registry_create(CPI_AGENT_ABI_VERSION, &registry);
    if (status != CPI_AGENT_OK) {
        return status;
    }

    status = cpi_agent_registry_add_lua(registry, SOURCE_NAME("extensions/read.lua"), read_source);
    if (status != CPI_AGENT_OK) {
        goto failed;
    }

    status = cpi_agent_registry_add_lua(registry, SOURCE_NAME("extensions/bash.lua"), bash_source);
    if (status != CPI_AGENT_OK) {
        goto failed;
    }

    *out_registry = registry;
    return CPI_AGENT_OK;

failed:
    cpi_agent_registry_destroy(registry);
    return status;
}

cpi_agent_status open_initial_agent(cpi_agent_bytes read_source,
                                    cpi_agent_bytes bash_source,
                                    const cpi_agent_config *config,
                                    cpi_agent **out_agent)
{
    cpi_agent_registry *registry = NULL;
    *out_agent = NULL;

    cpi_agent_status status = register_initial_capabilities(read_source, bash_source, &registry);
    if (status != CPI_AGENT_OK) {
        return status;
    }

    status = cpi_agent_open(registry, config, out_agent);
    cpi_agent_registry_destroy(registry);
    return status;
}

cpi_agent_status queue_session_capability_updates(cpi_agent *agent,
                                            cpi_agent_bytes read_request_id,
                                            cpi_agent_bytes read_source,
                                            cpi_agent_bytes bash_request_id,
                                            cpi_agent_bytes bash_source)
{
    cpi_agent_status status = cpi_agent_register_lua(
        agent, read_request_id, SOURCE_NAME("extensions/read.lua"), read_source);
    if (status != CPI_AGENT_OK) {
        return status;
    }

    return cpi_agent_register_lua(
        agent, bash_request_id, SOURCE_NAME("extensions/bash.lua"), bash_source);
}
