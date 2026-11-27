local function formatOutput(tail, outputPath, empty)
    local text=tail.content
    if text=='' then return empty end
    if #text<=maxBytes and tail.totalLines<=maxLines then return text end

    -- Count backwards over complete lines; a final newline is not a line.
    local last=#text - (string.sub(text,-1)=='\n' and 1 or 0)
    local reversed=string.reverse(text)
    local start,shown=last+1,0
    local sizeLimit,partialLine=false,nil
    while start>1 and shown<maxLines do
        local stop=if shown==0 then last else start-2
        local newline=string.find(reversed,'\n',#text-stop+1,true)
        local first=if newline then #text-newline+2 else 1
        if last-first+1>maxBytes then
            sizeLimit=true
            if shown==0 then
                start=last-maxBytes+1
                while string.byte(text,start)>=128 and string.byte(text,start)<192 do start+=1 end
                partialLine=last-first+1
                shown=1
            end
            break
        end
        start=first; shown+=1
    end
    local content=string.sub(text,start,last)
    if content=='' then content=empty end
    local suffix=if sizeLimit then ' (' .. formatSize(maxBytes) .. ' limit)' else ''
    local shownLines=if partialLine then string.format('Showing last %s of line %d (line is %s)',formatSize(#content),tail.totalLines,formatSize(partialLine))
        else string.format('Showing lines %d-%d of %d%s',tail.totalLines-shown+1,tail.totalLines,tail.totalLines,suffix)
    local fullOutput='Full output: ' .. outputPath
    local truncated=if sizeLimit then string.format('%d lines shown%s',shown,suffix) else string.format('showing %d of %d lines',shown,tail.totalLines)
    return content .. '\n\n[' .. shownLines .. '. ' .. fullOutput .. ']', {
        outputBytes=#content, warning='[' .. fullOutput .. '. Truncated: ' .. truncated .. ']',
    }
end
local function execute(args)
    assert(not string.find(args.command,'\000',1,true), 'CommandContainsNul')
    local timeout=args.timeout
    if timeout~=nil then assert(timeout>0 and timeout<=2147483.647 and timeout==timeout,'InvalidTimeoutSeconds') end
    local request={argv={'/bin/bash','-c',args.command},cwd=WORKSPACE}
    if timeout~=nil then request.timeout_ms=math.floor(timeout*1000) end
    local r=host.call('process.exec',request)
    local text,details=formatOutput(r.output,r.output_path,if r.timed_out then '' else '(no output)')
    local status=if r.timed_out then 'Command timed out after ' .. tostring(timeout) .. ' seconds'
        elseif r.exit_code~=0 then 'Command exited with code ' .. tostring(r.exit_code) else nil
    if status then
        text=(if text=='' then '' else text .. '\n\n') .. status
        if details then details.status=status end
    end
    return result(text,details,status~=nil)
end
