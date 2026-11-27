local function result(text, details, failed)
    return {content={{type='text', text=text}}, details=details, isError=failed or false}
end
local function natural(n, default)
    if n == nil then return default end
    assert(type(n)=='number' and n >= 0 and n < 9007199254740992 and n == math.floor(n), 'ExpectedNonnegativeInteger')
    return n
end
local function replace(text, needle, replacement)
    local out,at={},1
    while true do
        local first,last=string.find(text,needle,at,true)
        if not first then table.insert(out,string.sub(text,at)); return table.concat(out) end
        table.insert(out,string.sub(text,at,first-1)); table.insert(out,replacement)
        at=last+1
    end
end
-- Pi's model-facing budgets. Services still return the full selected output.
local maxLines, maxBytes = 2000, 50*1024
local function formatSize(bytes)
    if bytes < 1024 then return tostring(bytes) .. 'B' end
    if bytes < 1024*1024 then return string.format('%.1fKB', bytes/1024) end
    return string.format('%.1fMB', bytes/(1024*1024))
end
local function trimNewline(text)
    return string.sub(text,-1)=='\n' and string.sub(text,1,-2) or text
end
local function path(input)
    assert(type(input)=='string' and not string.find(input, '\000', 1, true), 'PathContainsNul')
    local parts = {}
    for _, cp in utf8.codes(input) do
        table.insert(parts, (cp==0xa0 or (cp>=0x2000 and cp<=0x200a) or cp==0x202f or cp==0x205f or cp==0x3000) and ' ' or utf8.char(cp))
    end
    local p = table.concat(parts)
    if string.sub(p,1,1)=='@' then p=string.sub(p,2) end
    if p=='~' or string.sub(p,1,2)=='~/' then
        assert(HOME~='', 'HomeDirectoryUnavailable')
        p=HOME .. string.sub(p,2)
    end
    if string.sub(p,1,7)=='file://' then
        p=string.sub(p,8)
        if string.sub(p,1,1)~='/' then
            local slash=string.find(p,'/',1,true)
            assert(slash and string.sub(p,1,slash-1)=='localhost', 'InvalidFileUrlHost')
            p=string.sub(p,slash)
        end
        local suffix=math.min(string.find(p,'?',1,true) or #p+1,string.find(p,'#',1,true) or #p+1)
        p=string.sub(p,1,suffix-1)
        local decoded,at={},1
        while at<=#p do
            if string.sub(p,at,at)=='%' then
                local byte=tonumber(string.sub(p,at+1,at+2),16)
                assert(byte and at+2<=#p,'InvalidFileUrl')
                table.insert(decoded,string.char(byte)); at+=3
            else table.insert(decoded,string.sub(p,at,at)); at+=1 end
        end
        p=table.concat(decoded)
        assert(not string.find(p,'\000',1,true), 'PathContainsNul')
    end
    if string.sub(p,1,1)~='/' then p=WORKSPACE .. '/' .. p end
    local segments={}
    local at=1
    while at<=#p do
        local slash=string.find(p,'/',at,true) or #p+1
        local segment=string.sub(p,at,slash-1)
        if segment=='..' then table.remove(segments) elseif segment~='.' and segment~='' then table.insert(segments,segment) end
        at=slash+1
    end
    return '/' .. table.concat(segments,'/')
end
local function lines(text, terminalEmpty)
    local out, at={},1
    while true do
        local stop=string.find(text,'\n',at,true)
        if not stop then
            if at<=#text or terminalEmpty then table.insert(out,string.sub(text,at)) end
            return out
        end
        table.insert(out,string.sub(text,at,stop))
        at=stop+1
    end
end
local function lf(text)
    return replace(replace(text,'\r\n','\n'),'\r','\n')
end
local function guarded(name, execute, args)
    local ok, value=pcall(execute,args)
    if ok then return value end
    -- Translate known filesystem errors at the tool boundary. Leave unknown
    -- service faults intact rather than misreporting them as missing files.
    local message=tostring(value)
    local read=string.find(message,'host files.read failed: ',1,true)==1
    if args.path and (read or string.find(message,'host files.write failed: ',1,true)==1) then
        local errno
        for code, mapped in pairs({FileNotFound='ENOENT',AccessDenied='EACCES',PermissionDenied='EACCES',NotDir='ENOTDIR',IsDir='EISDIR'}) do
            if string.find(message,'"code":"' .. code .. '"',1,true) then errno=mapped; break end
        end
        if errno then
            if name=='edit' and read and errno~='EISDIR' then
                return result('Could not edit file: ' .. args.path .. '. Error code: ' .. errno .. '.',nil,true)
            end
            local reason=({ENOENT='no such file or directory',EACCES='permission denied',ENOTDIR='not a directory',EISDIR='illegal operation on a directory'})[errno]
            local action=if read then 'access' else 'open'
            return result(string.format("%s: %s, %s '%s'",errno,reason,action,path(args.path)),nil,true)
        end
    end
    return result(name .. ': ' .. tostring(value) .. (args.path and (' at ' .. args.path) or ''), nil, true)
end
