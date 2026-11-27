"""Test-only reader for version-1 semantic session journals."""
import copy
import gzip
import json
from pathlib import Path

OPS = {
    'capability.bind', 'capability.unbind', 'control.set_model',
    'control.provider_tool.register', 'control.provider_tool.deregister',
    'control.extension', 'document.message.append', 'control.context.create',
    'control.context.select', 'control.document_mutation', 'control.model.request',
    'control.model.finish', 'control.effect.intent', 'control.effect.result', 'control.cancel',
}


def read_frames(source):
    data = Path(source).read_bytes() if isinstance(source, (str, Path)) else source
    frames = [json.loads(line) for line in gzip.decompress(data).splitlines()]
    session = None
    transaction = None
    index = 0
    ids = set()
    for expected, frame in enumerate(frames, 1):
        assert set(frame) == {'v', 'session_id', 'seq', 'tx', 'class', 'op', 'actor', 'cause', 'data'}
        assert frame['v'] == 1 and frame['seq'] == expected and frame['op'] in OPS
        assert frame['class'] == ('capability' if frame['op'].startswith('capability.') else 'document' if frame['op'].startswith('document.') else 'control')
        session = session or frame['session_id']
        assert frame['session_id'] == session
        group = frame['tx']
        if transaction is None:
            assert group['id'] not in ids and group['index'] == 0 and group['count'] > 0
            transaction = group
            ids.add(group['id'])
            index = 0
        assert group['id'] == transaction['id'] and group['count'] == transaction['count'] and group['index'] == index
        index += 1
        if index == group['count']:
            transaction = None
    assert transaction is None
    return frames


def encode(frames):
    if isinstance(frames, dict):
        frames = [frames]
    result = bytearray()
    start = 0
    while start < len(frames):
        count = frames[start]['tx']['count']
        assert len(frames[start:start + count]) == count
        text = ''.join(json.dumps(frame, ensure_ascii=False, separators=(',', ':')) + '\n' for frame in frames[start:start + count])
        result.extend(gzip.compress(text.encode(), mtime=0))
        start += count
    return bytes(result)


def action_frame(session, sequence, op, data, transaction=None, index=0, count=1):
    return {'v': 1, 'session_id': session, 'seq': sequence,
            'tx': {'id': transaction or f'fixture-{sequence}', 'index': index, 'count': count},
            'class': 'capability' if op.startswith('capability.') else 'document' if op.startswith('document.') else 'control',
            'op': op, 'actor': {'kind': 'host', 'id': 'fixture'}, 'cause': None, 'data': data}


def extension_frame(session, sequence, namespace, action, value, expected_head=0):
    return action_frame(session, sequence, 'control.extension', {
        'namespace': namespace, 'expected_head': expected_head, 'action': action,
        'input': {'contract': {'id': namespace, 'version': '1'}, 'value': value},
    })


def write_frames(path, frames):
    Path(path).write_bytes(encode(frames))


def append_frames(path, frames):
    with Path(path).open('ab') as output:
        output.write(encode(frames))


def fixture_frames(session, state, minimal=False):
    """Create a new-format harness fixture, not a reader for old persisted data."""
    runtime = {key: copy.deepcopy(value) for key, value in state.items() if key not in ('ctx', 'closing', 'closed', 'close_id')}
    conversation = runtime.get('conversation', {'head': None, 'next': 1, 'revision': 0})
    entries = conversation.pop('entries', [])
    runtime['conversation'] = conversation
    for slot in ('active', 'suspended'):
        run = runtime.get(slot)
        if isinstance(run, dict):
            runtime[slot] = True
            runtime.update({slot + '/' + key: value for key, value in run.items()})
    values = {key: json.dumps(value, separators=(',', ':')) for key, value in runtime.items()}
    frames = [extension_frame(session, 1, 'agent.luau.runtime', 'assign', values)]
    ctx = state.get('ctx', {})
    if minimal:
        change = {'assign': [{'name': key, 'json': json.dumps(value, separators=(',', ':'))} for key, value in ctx.items()], 'erase': []}
        if change['assign']:
            frames.append(extension_frame(session, 2, 'cpi-minimal.ctx', 'assign', change))
    else:
        frames.append(extension_frame(session, 2, 'agent.luau.ctx', 'capture', json.dumps(ctx, separators=(',', ':'))))
    messages = []
    for entry in entries:
        key = 'conversation/' + entry['id']
        if entry['kind'] == 'branch':
            head = max((f['seq'] for f in frames if f['op'] == 'control.extension' and f['data']['namespace'] == 'agent.luau.history'), default=0)
            frames.append(extension_frame(session, len(frames) + 1, 'agent.luau.history', 'put', {'id': key, 'json': json.dumps(entry)}, head))
            continue
        role = 'assistant' if entry['kind'] in ('response', 'model_result') else 'user'
        content = [{'type': 'json', 'value': {'format': 'agent.luau.entry.v1', 'stream': 'conversation', 'json': json.dumps(entry)}}]
        frames.append(action_frame(session, len(frames) + 1, 'document.message.append', {'message': {'id': key, 'role': role, 'content': content}, 'placement': {'context': 'main', 'after': messages[-1] if messages else None}}))
        messages.append(key)
    return frames


def session_state(source, position=None):
    frames = read_frames(source)
    if position is None:
        position = len(frames)
    assert 0 <= position <= len(frames)
    assert position == 0 or frames[position - 1]['tx']['index'] + 1 == frames[position - 1]['tx']['count']
    state = {'sequence': position, 'extensions': {}, 'messages': {}, 'contexts': {'main': []}, 'selected': 'main', 'effects': {}, 'requests': {}, 'history': []}
    prefixes = {0: {'main': []}}
    heads = {}
    entry_heads = {}
    for frame in frames[:position]:
        op, data, seq = frame['op'], frame['data'], frame['seq']
        if frame['tx']['index'] == 0:
            entry_heads = dict(heads)
        if op == 'control.extension':
            ns = data['namespace']
            assert data['expected_head'] == entry_heads.get(ns, 0)
            assert data['input']['contract'] == {'id': ns, 'version': '1'}
            value = data['input']['value']
            if ns == 'agent.luau.runtime':
                previous = state['extensions'].setdefault(ns, {})
                for key, item in value.items():
                    if item is None:
                        previous.pop(key, None)
                    else:
                        previous[key] = item
            elif ns in ('agent.luau.commands', 'agent.luau.history'):
                state['extensions'].setdefault(ns, {})[value['id']] = value['json']
            elif ns == 'cpi-minimal.ctx':
                previous = state['extensions'].setdefault(ns, {})
                for key in value['erase']:
                    del previous[key]
                for item in value['assign']:
                    previous[item['name']] = item['json']
            elif ns in ('agent.luau.ctx', 'cpi-terminus.ctx', 'cpi-terminus.binding'):
                state['extensions'][ns] = value
            else:
                raise ValueError(f'missing private reducer {ns}')
            if ns == 'agent.luau.history':
                state['history'].append((value['id'].split('/', 1)[0], json.loads(value['json'])))
            heads[ns] = seq
        elif op == 'document.message.append':
            message = data['message']
            assert message['id'] not in state['messages']
            state['messages'][message['id']] = message
            for part in message['content']:
                value = part.get('value', {})
                if value.get('format') == 'agent.luau.entry.v1':
                    state['history'].append((value['stream'], json.loads(value['json'])))
            if data['placement'] is not None:
                selected = state['contexts'][data['placement']['context']]
                after = data['placement']['after']
                selected.insert(0 if after is None else selected.index(after) + 1, message['id'])
        elif op == 'control.context.create':
            base = data['base']
            state['contexts'][data['id']] = [] if base is None else list(prefixes[base['at']][base['context']])
        elif op == 'control.context.select':
            state['selected'] = data['context']
        elif op == 'control.document_mutation':
            selected = state['contexts'][data['context']]
            for edit in data['edits']:
                if edit['op'] == 'drop':
                    for key in edit['ids']:
                        selected.remove(key)
                else:
                    index = 0 if edit['after'] is None else selected.index(edit['after']) + 1
                    selected[index:index] = edit['ids']
        elif op == 'control.model.request':
            state['requests'][data['request_id']] = {'intent': seq, 'data': data, 'finish': None}
        elif op == 'control.model.finish':
            state['requests'][data['request_id']]['finish'] = data
        elif op == 'control.effect.intent':
            state['effects'][data['effect_id']] = {'intent': seq, 'data': data, 'finish': None, 'result_frame': None}
        elif op == 'control.effect.result':
            state['effects'][data['effect_id']].update(finish=data, result_frame=seq)
        if frame['tx']['index'] + 1 == frame['tx']['count']:
            prefixes[seq] = copy.deepcopy(state['contexts'])
    return state


def runtime_state(source):
    state = session_state(source)
    private = state['extensions']
    root = {key: json.loads(value) for key, value in private.get('agent.luau.runtime', {}).items()}
    for slot in ('active', 'suspended'):
        if root.get(slot) is True:
            root[slot] = {key[len(slot)+1:]: value for key, value in root.items() if key.startswith(slot + '/')}
    root = {key: value for key, value in root.items() if not key.startswith(('active/', 'suspended/'))}
    if 'cpi-minimal.ctx' in private:
        root['ctx'] = {key: json.loads(value) for key, value in private['cpi-minimal.ctx'].items()}
    else:
        root['ctx'] = json.loads(private.get('cpi-terminus.ctx', private.get('agent.luau.ctx', '{}')))
    streams = {'application': [], 'conversation': []}
    for stream, value in state['history']:
        streams[stream].append(value)
    root.setdefault('conversation', {})['entries'] = streams['conversation']
    root['commands'] = [json.loads(value) for value in private.get('agent.luau.commands', {}).values()] + root.get('commands', [])
    graph = root.get('ctx', {}).get('session')
    if graph is not None:
        graph['entries'] = {entry['id']: entry for entry in streams['application']}
        graph['order'] = [entry['id'] for entry in streams['application']]
    results = {effect['result_frame']: effect for effect in state['effects'].values() if effect['finish'] is not None}
    def expand(value):
        if isinstance(value, list):
            return [expand(item) for item in value]
        if not isinstance(value, dict):
            return value
        if 'effect_ref' in value and 'tool_name' in value and 'status' in value:
            effect = results[value['effect_ref']]
            return {**{key: item for key, item in value.items() if key != 'effect_ref'},
                    'endpoint': effect['data']['endpoint']['name'],
                    'arguments': json.loads(effect['data']['arguments']['json']),
                    'result': json.loads(effect['finish']['result']['json'])}
        return {key: expand(item) for key, item in value.items()}
    return expand(root)


def command_records(source):
    return runtime_state(source)['commands']


def private_context(source):
    state = session_state(source)
    return {key: json.loads(value) for key, value in state['extensions'].get('cpi-minimal.ctx', {}).items()}


def context_change(frames, ctx):
    previous = private_context(encode(frames))
    head = max((frame['seq'] for frame in frames if frame['op'] == 'control.extension' and frame['data']['namespace'] == 'cpi-minimal.ctx'), default=0)
    change = {'assign': [{'name': key, 'json': json.dumps(value, separators=(',', ':'))} for key, value in ctx.items() if previous.get(key, object()) != value], 'erase': [key for key in previous if key not in ctx]}
    return extension_frame(frames[0]['session_id'], len(frames) + 1, 'cpi-minimal.ctx', 'assign', change, head)


def runtime_change(frames, changes):
    head = max((frame['seq'] for frame in frames if frame['op'] == 'control.extension' and frame['data']['namespace'] == 'agent.luau.runtime'), default=0)
    return extension_frame(frames[0]['session_id'], len(frames) + 1, 'agent.luau.runtime', 'assign', {key: json.dumps(value, separators=(',', ':')) for key, value in changes.items()}, head)
