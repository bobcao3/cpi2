local function row(role, text, mark)
    return {mark=mark, spans={{role=role, text=text}}}
end

local function startup(expanded, showResources)
    local rows = {row('version', 'cpi-minimal v', 'title')}
    local hints = if expanded then {
        {'escape', 'to interrupt'}, {'ctrl+c', 'to clear'}, {'ctrl+c twice', 'to exit'}, {'ctrl+d', 'to exit (empty)'},
        {'ctrl+k', 'to delete to end'}, {'{cycle_thinking}', 'to cycle thinking level'}, {'{select_model}', 'to select model'},
        {'{expand_tools}', 'to expand tools'}, {'{toggle_thinking}', 'to expand thinking'}, {'{external_editor}', 'for external editor'},
        {'/', 'for commands'}, {'!', 'to run bash'}, {'!!', 'to run bash (no context)'},
        {'{follow_up}', 'to queue follow-up'}, {'{restore_queued}', 'to edit all queued messages'},
    } else {
        {'escape', 'interrupt'}, {'ctrl+c/ctrl+d', 'clear/exit'}, {'/', 'commands'}, {'!', 'bash'}, {'{expand_tools}', 'more'},
    }
    if expanded and jobControl then table.insert(hints, 5, {'ctrl+z', 'to suspend'}) end
    local line = {mark='hints', spans={}}
    for index, hint in ipairs(hints) do
        if index > 1 and expanded then line = {spans={}}
        elseif index > 1 then table.insert(line.spans, {role='muted', text=' · '}) end
        if index == 1 or expanded then table.insert(rows, line) end
        table.insert(line.spans, {role='dim', text=hint[1]})
        table.insert(line.spans, {role='muted', text=' ' .. hint[2]})
    end
    if not expanded then
        table.insert(rows, row('dim', if showResources then 'Press {expand_tools} to show full startup help and loaded resources.'
            else 'Press {expand_tools} to show full startup help.'))
    end
    table.insert(rows, {})
    table.insert(rows, row('dim', 'cpi-minimal can explain its own features and look up its docs. Ask it how to use or extend cpi-minimal.'))
    return rows
end

local function command(action, description, arguments, completion, argumentHint)
    return {name='/' .. action, action=action, description=description, arguments=arguments, completion=completion, argument_hint=argumentHint}
end

local commands = {
    command('settings', 'Open settings menu', 'exact'),
    command('model', 'Select model (opens selector UI)', nil, 'model', '<provider/model>'),
    command('tree', 'Navigate session tree (switch branches)'),
    command('thinking', 'Set thinking level', nil, 'thinking', '<level>'),
    {name='/export', action='export_session', description='Export the selected branch as Markdown or .jsonl'},
    command('copy', 'Copy last agent message to clipboard'),
    command('name', 'Set session display name'),
    command('session', 'Show session info and stats', 'none'),
    command('hotkeys', 'Show all keyboard shortcuts', 'none'),
    command('fork', 'Create a new fork from a previous user message'),
    command('clone', 'Duplicate the current session at the current position', 'exact'),
    command('login', 'Configure provider authentication', nil, 'login', '<provider>'),
    command('logout', 'Remove provider authentication', 'exact'),
    command('new', 'Start a new session', 'none'),
    command('compact', 'Manually compact the session context'),
    command('resume', 'Resume another session'),
    command('reload', 'Reload skills and context files', 'none'),
    command('quit', 'Quit cpi-minimal', 'none'),
    command('help', 'Show available commands and shortcuts', 'none'),
    command('continue', 'Answer the unresolved conversation', 'none'),
    command('reset', 'Reset the context with an optional handoff note'),
    command('select', 'Continue from a session entry'),
    command('send', 'Send text literally'),
    command('queue', 'Manage queued messages'),
    command('draft', 'Restore a displaced draft', 'none'),
    command('outcome', 'Show or dismiss the latest outcome'),
    command('forget', 'Remove saved provider credentials'),
}

local function preference(id, label, description, requiresImages)
    return {id=id, label=label, description=description, requires_images=requiresImages}
end

local settings = {
    preference('auto_compact', "Auto-compact", "Automatically compact context when it gets too large"),
    preference('show_images', "Show images", "Render images inline in terminal", true),
    preference('image_width', "Image width", "Preferred inline image width in terminal cells", true),
    preference('auto_resize_images', "Auto-resize images", "Resize large images to 2000x2000 max for better model compatibility"),
    preference('block_images', "Block images", "Prevent images from being sent to LLM providers"),
    preference('skill_commands', "Skill commands", "Register skills as /skill:name commands"),
    preference('show_hardware_cursor', "Show hardware cursor", "Use the terminal cursor instead of Pi's drawn cursor"),
    preference('editor_padding', "Editor padding", "Horizontal padding for input editor (0-3)"),
    preference('output_padding', "Output padding", "Horizontal padding for messages, tool output, and command output"),
    preference('autocomplete_max_items', "Autocomplete max items", "Max visible items in autocomplete dropdown (3-20)"),
    preference('clear_on_shrink', "Clear on shrink", "Clear empty rows when content shrinks (may cause flicker)"),
    preference('terminal_progress', "Terminal progress", "Show OSC 9;4 progress indicators in the terminal tab bar"),
    preference('steering_mode', "Steering mode", "Enter while streaming queues steering messages. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once."),
    preference('follow_up_mode', "Follow-up mode", "{Follow_up} queues follow-up messages until agent stops. 'one-at-a-time': deliver one, wait for response. 'all': deliver all at once."),
    preference('transport', "Transport", "Preferred transport for providers that support multiple transports"),
    preference('hide_thinking', "Hide thinking", "Hide thinking blocks in assistant responses"),
    preference('quiet_startup', "Quiet startup", "Disable verbose printing at startup (header: keep only the startup header)"),
    preference('double_escape', "Double-escape action", "Action when pressing Escape twice with empty editor"),
    preference('tui_mode', "TUI mode", "Interface layout; regular mode uses the terminal's normal scrollback"),
    preference('fullscreen_exit_output', "Fullscreen exit output", "Print the transcript or only a session resume hint when exiting fullscreen mode"),
    preference('fullscreen_scrollbar', "Fullscreen scrollbar", "Scrollbar behavior in fullscreen mode; has no effect in regular mode"),
    preference('fullscreen_copy_on_select', "Fullscreen copy on select", "Automatically copy selected text in fullscreen mode; disable to copy selections with Ctrl+X"),
    preference('fullscreen_wheel', "Fullscreen wheel scrolling", "Lines per mouse-wheel event in fullscreen mode; 'auto' speeds up fast wheel spins where the terminal does not"),
    preference('theme', "Theme", "Color theme for the interface"),
}

local hotkeys = [[Enter sends or steers · {Follow_up} queues a follow-up
Esc interrupts · Ctrl+C clears · Ctrl+C twice quits · Ctrl+D quits empty
Tab completes · {Cycle_thinking} cycles thinking effort · {Select_model} opens models
{Expand_tools} toggles tool output · {Toggle_thinking} toggles thinking
{External_editor} opens the draft in an external editor
! runs bash · !! runs bash with output visible only in the transcript
{Restore_queued} restores queued messages · /draft restores a displaced draft
Ctrl+- undoes edits · Ctrl+Y yanks · Alt+Y cycles recent kills
Page Up/Down scrolls · Shift+Enter or Ctrl+J inserts a newline]]
local function searchCard(heading, rows, limit, field, unit)
    return {heading=heading, collapsed_rows=rows, limit=limit, warning_field=field, warning_unit=unit}
end

local function searchBody()
    return {{component='result', when='complete'}, {component='search_warning', when='complete'}}
end

local function scriptBody(when)
    return {
        {component='script_source', when=when, collapsed_rows=10, highlight=true},
        {component='script_calls', when=when, collapsed_rows=8},
        {component='script_output', when=when or 'complete', collapsed_rows=5},
        {component='duration', when=when},
    }
end

local function decoration(text, role, bold, clip)
    return {text=text, role=role, bold=bold, clip=clip}
end
local function gap()
    return {kind='gap'}
end

local function rule(role, clip)
    return {kind='rule', role=role, clip=clip}
end

local function themeIntro()
    return {
        decoration('Automatic Theme', 'accent', true), gap(),
        decoration('Choose themes for terminal light and dark appearance.', 'muted'),
        decoration('Light/dark detection requires terminal support.', 'muted'), gap(),
    }
end

local function themeFrame(title, description, automatic)
    local before = if automatic then themeIntro() else {}
    table.insert(before, decoration(title, 'accent', true))
    table.insert(before, gap())
    table.insert(before, decoration(description, 'muted'))
    table.insert(before, gap())
    return {before=before, after={gap(), decoration('  Enter to select · Esc to go back', 'dim')}}
end

local ui = {
    startup={compact=startup(false, true), header=startup(false, false), expanded=startup(true, false)},
    settings=settings, commands=commands, hotkeys=hotkeys,
    shortcuts={expand_tools='ctrl+o', toggle_thinking='ctrl+t', cycle_thinking='shift+tab', select_model='ctrl+l', external_editor='ctrl+g',
        follow_up=if windowsKeys then 'ctrl+q' else 'alt+enter', restore_queued=if windowsKeys then 'alt+q' else 'alt+up'},
    pending_hint='↳ {Restore_queued} to edit all queued messages',
    queue_labels={steering='Steering', follow_up='Follow-up'},
    footer={'location', 'status'},
    shell={collapsed_rows=20},
    syntax={
        keyword='syntaxKeyword', conditional='syntaxKeyword', import='syntaxKeyword', preproc='muted', type='syntaxType', constructor='syntaxType',
        boolean='syntaxNumber', constant='syntaxNumber', number='syntaxNumber', string='syntaxString', character='syntaxString', escape='syntaxString',
        comment='syntaxComment', tag='syntaxPunctuation', delimiter='syntaxPunctuation',
        operator='syntaxOperator', punctuation='syntaxPunctuation', ['function']='syntaxFunction', method='syntaxFunction',
        attribute='syntaxVariable', property='syntaxVariable', field='syntaxVariable', variable='syntaxVariable', parameter='syntaxVariable',
        ['string.special.key']='syntaxVariable', embedded='text',
        addition='toolDiffAdded', deletion='toolDiffRemoved', emphasis='italic', strong='bold', link='underline',
    },
    transcript={hidden_thinking_label='Thinking...'},
    session_export={filename_prefix='cpi-minimal-session-', success='Session exported to: ', failure='Failed to export session: '},
    session_info={in_memory='In-memory', rows={
        decoration('Session Info', nil, true), gap(),
        {text='Name:', field='name', role='dim'},
        {text='File:', field='file', role='dim'},
        {text='ID:', field='id', role='dim'}, gap(),
        decoration('Messages', nil, true),
        {text='Total:', field='messages', role='dim'},
        {text='User:', field='user', role='dim'},
        {text='Assistant:', field='assistant', role='dim'},
        {text='Tools:', field='tools', role='dim'}, gap(),
        decoration('Tokens', nil, true),
        {text='Input:', field='input', role='dim'},
        {text='  Cached:', field='cached', role='dim'},
        {text='  Uncached:', field='uncached', role='dim'},
        {text='Output:', field='output', role='dim'},
        {text='Total:', field='tokens', role='dim'},
    }},
    pickers={
        fork={before={gap(), decoration(' Fork from Message', nil, true),
            decoration(' Select a user message to copy the active path up to that point into a new session', 'muted'), gap(), rule('border'), gap()},
            after={gap(), rule('border')}},
        thinking={before={decoration('[ THINKING ]  ↑/↓ select · Enter apply · Esc cancel', nil, true)}},
        theme={
            single=themeFrame('Theme', 'Select a theme, or choose automatic to follow terminal appearance.', false),
            automatic={before=themeIntro()},
            light=themeFrame('Light Theme', 'Select the theme to use for light terminal appearance', true),
            dark=themeFrame('Dark Theme', 'Select the theme to use for dark terminal appearance', true),
        },
        tree={
            help={'↑/↓ move', '←/→ page', if macKeys then 'alt+←/→ branch' else 'ctrl+←/→ branch', 'ctrl+x copy',
                'shift+l label', 'shift+t label time', 'filters ctrl+d/t/u/l/a', 'cycle ctrl+o/shift+ctrl+o'},
            search_prompt='  Type to search: ',
            filter_suffix={default='', no_tools=' [no-tools]', user=' [user]', labeled=' [labeled]', all=' [all]'},
            summary_choices={navigate='No summary', summarize='Summarize', custom_prompt='Summarize with custom prompt'},
            list={before={gap(), rule('border', true), decoration('   Session Tree', nil, true, true)}, after={gap(), rule('border', true)}},
            confirm={before={rule('border', true), gap(), decoration(' Summarize branch?', 'accent', true, true), gap()},
                after={gap(), decoration(' ↑↓ navigate  enter select  esc cancel', 'muted', nil, true), gap(), rule('border', true)}},
            custom_prompt={before={rule('border', true), gap(), decoration(' Custom summarization instructions', 'accent', nil, true), gap()},
                after={gap(), decoration(' enter submit  shift+enter newline  esc cancel  {external_editor} external editor', 'muted'), gap(), rule('border', true)}},
            label={before={decoration('  Label (empty to remove):', 'muted', nil, true)},
                after={decoration('  enter save  esc cancel', 'muted', nil, true)}},
        },
        resume_picker={
            frame={before={gap(), rule('accent', true), gap()}, after={gap(), rule('accent', true)}},
            current={title='Resume Session (Current Folder)', empty='  No sessions in current folder. Press Tab to view all.',
                empty_named='  No named sessions in current folder. Press ctrl+n to show all, or Tab to view all.'},
            all={title='Resume Session (All)', empty='  No sessions found', empty_named='  No named sessions found. Press ctrl+n to show all.'},
            search_hint='tab scope · fuzzy search · "phrase" exact',
            bindings='ctrl+s sort · ctrl+n named · ctrl+d delete · ctrl+p path ',
            path_hint={'(off)', '(on)'}, rename_hint=' · ctrl+r rename',
            delete_confirmation='Delete session? enter confirm · escape/ctrl+c cancel',
        },
        rename_session={before={gap(), rule('accent', true), gap(), decoration(' Rename Session', nil, true, true), gap()},
            after={gap(), decoration(' enter to save · escape/ctrl+c to cancel', 'muted', nil, true), gap(), rule('accent', true)}},
        workspace={title_prefix='Session cwd does not exist: ',
            proceed={'Continue in ', ' (asks again next time)'}, fork={'Fork into ', ' (new session ID, original kept)'},
            cancel='Cancel', hint='↑↓ navigate  enter select  escape/ctrl+c cancel'},
        dialog={
            title={providers='[ LOGIN ]  Authorize again · /model switches saved providers', endpoint='[ LOGIN ]  Responses base URL',
                key='[ LOGIN ]  API key (hidden)', models='[ MODEL ]  Filter listed models · Ctrl+N custom ID',
                custom='[ MODEL ]  Explicit custom model ID', confirm='[ FORGET ]  Confirm local credential removal', waiting='[ LOGIN ]  Waiting',
                logout='[ LOGOUT ]  Select a saved provider'},
            hint='Tab / Shift+Tab / arrows select · Enter apply · Ctrl+B back · Esc / Ctrl+C / Ctrl+D cancel',
            rows={
                {component='title', look='strong'},
                {component='destination', text='Destination: ', look='muted'},
                {component='account', text='Account: ', look='muted'},
                {component='message', look='muted'},
                {component='choices', text='No matching choices.', look='muted'},
                {component='input', text='> ', look='strong'},
                {component='hint', look='muted'},
            },
            providers={
                openai={label='OpenAI subscription', auth_type='oauth', type_label='subscription'},
                deepseek={label='DeepSeek API', auth_type='api_key', type_label='API key'},
                compatible={label='OpenAI-compatible Responses server', auth_type='api_key', type_label='API key'},
            },
            no_saved_providers='No stored credentials to remove. /logout removes saved credentials. Environment credentials are unchanged.',
        },
    },
    search={
        grep=searchCard('regex', 15, {' limit ', ''}, 'matchLimitReached', 'matches'),
        find=searchCard('pattern', 20, {' (limit ', ')'}, 'resultLimitReached', 'results'),
        ls=searchCard('file', 20, {' (limit ', ')'}, 'entryLimitReached', 'entries'),
        byte_warning='50.0KB limit',
        line_warning='some lines truncated',
    },
    tools={
        read={
            {component='result', when='expanded_or_failed', collapsed_rows=10, highlight=true},
            {component='read_limit', when='expanded_or_failed'},
            {component='image_warning', when='complete'},
        },
        write={
            {component='content', collapsed_rows=10, highlight=true, show_total=true},
            {component='error_message', when='failed'},
        },
        edit={{component='diff'}},
        bash={{component='tail', collapsed_rows=5}, {component='shell_warning', when='complete'}, {component='duration'}},
        grep=searchBody(), find=searchBody(), ls=searchBody(),
        execute_lua=scriptBody(),
        other={{component='result', when='complete', collapsed_rows=10}},
    },
}

local treeDefaults = table.clone(ui.pickers.tree)
local resumeDefaults, workspaceDefaults = ui.pickers.resume_picker, ui.pickers.workspace
local dialogDefaults, logoutTitle = table.clone(ui.pickers.dialog), ui.pickers.dialog.title.logout
local sessionInfoDefaults = ui.session_info

local function finish()
    if next(ui.footer) == nil then ui.footer = nil end
    if next(ui.syntax) == nil then ui.syntax = nil end
    for name, sections in pairs(ui.tools) do
        if type(sections) == 'table' then
            for i = #sections, 1, -1 do
                local section = sections[i]
                if type(section) == 'table' and section.component == 'script' then
                    table.remove(sections, i)
                    local parts = scriptBody(section.when)
                    for j = #parts, 1, -1 do table.insert(sections, i, parts[j]) end
                end
            end
            if next(sections) == nil then ui.tools[name] = nil end
        end
    end
    for action, chord in pairs(ui.shortcuts) do ui.shortcuts[action] = string.lower(chord) end
    local function label(text)
        return (string.gsub(text, '{([%a_]+)}', function(action)
            local chord = ui.shortcuts[string.lower(action)]
            if not chord or action == string.lower(action) then return chord end
            return (string.gsub(chord, '%a+', function(word) return string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2) end))
        end))
    end
    if ui.pickers.resume_picker == nil then ui.pickers.resume_picker = resumeDefaults end
    if ui.pickers.workspace == nil then ui.pickers.workspace = workspaceDefaults end
    if ui.session_info == nil then ui.session_info = sessionInfoDefaults end
    if next(ui.session_info.rows) == nil then ui.session_info.rows = nil end
    local dialog = ui.pickers.dialog
    if dialog.rows == nil then dialog.rows = dialogDefaults.rows
    elseif next(dialog.rows) == nil then dialog.rows = nil end
    if dialog.title.logout == nil then dialog.title.logout = logoutTitle end
    if dialog.providers == nil then dialog.providers = dialogDefaults.providers end
    if dialog.no_saved_providers == nil then dialog.no_saved_providers = dialogDefaults.no_saved_providers end
    for _, group in ipairs({ui.pickers, ui.pickers.theme, ui.pickers.tree, ui.pickers.resume_picker}) do
        for _, frame in pairs(group) do
            if type(frame) ~= 'table' then continue end
            for _, position in ipairs({'before', 'after'}) do
                local rows = frame[position]
                if rows then
                    if next(rows) == nil then frame[position] = nil end
                    for _, row in ipairs(rows) do
                        if row.text then row.text = label(row.text) end
                    end
                end
            end
        end
    end
    local tree = ui.pickers.tree
    for _, field in ipairs({'help', 'search_prompt', 'filter_suffix', 'summary_choices'}) do
        if tree[field] == nil then tree[field] = treeDefaults[field] end
    end
    local treeHelp = tree.help
    for i, hint in ipairs(treeHelp) do treeHelp[i] = label(hint) end
    if next(treeHelp) == nil then tree.help = nil end
    for _, rows in pairs(ui.startup) do
        for _, row in ipairs(rows) do
            for _, span in ipairs(row.spans or {}) do span.text = label(span.text) end
        end
    end
    for _, setting in ipairs(ui.settings) do setting.description = label(setting.description) end
    ui.pending_hint = label(ui.pending_hint)
    ui.hotkeys = label(ui.hotkeys)
    local names = {}
    for index, entry in ipairs(ui.commands) do
        names[index] = entry.name
        local hint = entry.argument_hint
        if hint and hint ~= '' then
            local description = entry.description or ''
            entry.description = if description == '' then hint else hint .. ' — ' .. description
        end
        entry.argument_hint = nil
    end
    ui.help = table.concat(names, '  ') .. '  /skill:NAME [args]\n' .. ui.hotkeys
    return ui
end
