#include <stdlib.h>
#include <string.h>
#include <yaml.h>

typedef struct {
    yaml_parser_t parser;
    yaml_event_t event;
    const unsigned char *input;
    size_t length;
} cpi_yaml_parser;
typedef struct {
    int type;
    int plain;
    int minor;
    const unsigned char *anchor;
    const unsigned char *tag;
    const unsigned char *value;
    size_t length;
} cpi_yaml_event;

void *cpi_yaml_create(const unsigned char *input, size_t length) {
    cpi_yaml_parser *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (!yaml_parser_initialize(&p->parser)) { free(p); return NULL; }
    yaml_parser_set_input_string(&p->parser, input, length);
    p->input = input;
    p->length = length;
    return p;
}
void cpi_yaml_destroy(void *context) {
    cpi_yaml_parser *p = context;
    yaml_event_delete(&p->event);
    yaml_parser_delete(&p->parser);
    free(p);
}
int cpi_yaml_next(void *context, cpi_yaml_event *out) {
    cpi_yaml_parser *p = context;
    yaml_event_delete(&p->event);
    memset(out, 0, sizeof(*out));
    if (!yaml_parser_parse(&p->parser, &p->event))
        return p->parser.error == YAML_MEMORY_ERROR ? -1 : 0;
    yaml_event_t *e = &p->event;
    if ((e->type == YAML_SCALAR_EVENT &&
         (e->data.scalar.style == YAML_SINGLE_QUOTED_SCALAR_STYLE ||
          e->data.scalar.style == YAML_DOUBLE_QUOTED_SCALAR_STYLE)) ||
        e->type == YAML_MAPPING_END_EVENT || e->type == YAML_SEQUENCE_END_EVENT) {
        size_t index = 0, characters = 0;
        while (index < p->length && characters < e->end_mark.index) {
            if ((p->input[index] & 0xc0) != 0x80) ++characters;
            ++index;
            while (index < p->length && (p->input[index] & 0xc0) == 0x80) ++index;
        }
        if (index < p->length && p->input[index] == '#') return 0;
    }
    out->type = e->type;
    switch (e->type) {
    case YAML_DOCUMENT_START_EVENT:
        if (e->data.document_start.version_directive)
            out->minor = e->data.document_start.version_directive->minor;
        break;
    case YAML_SCALAR_EVENT:
        out->anchor = e->data.scalar.anchor;
        out->tag = e->data.scalar.tag;
        out->value = e->data.scalar.value;
        out->length = e->data.scalar.length;
        out->plain = e->data.scalar.style == YAML_PLAIN_SCALAR_STYLE;
        break;
    case YAML_ALIAS_EVENT: out->anchor = e->data.alias.anchor; break;
    case YAML_MAPPING_START_EVENT:
        out->anchor = e->data.mapping_start.anchor;
        out->tag = e->data.mapping_start.tag;
        break;
    case YAML_SEQUENCE_START_EVENT:
        out->anchor = e->data.sequence_start.anchor;
        out->tag = e->data.sequence_start.tag;
        break;
    default: break;
    }
    return 1;
}
