local function execute(args)
    local selectedPath=path(args.path)
    local offset=math.max(1,natural(args.offset,1))
    local range={offset=offset}
    if args.limit~=nil then range.limit=natural(args.limit,0) end
    local file=host.call('files.read',{path=selectedPath,lossy_text=true,lines=range,inline_image=true})
    if type(file.mime_type)=='string' then
        if #file.base64>0 then output.image({mime_type=file.mime_type,data_base64=file.base64}) end
        local note=if type(file.image_note)=='string' and #file.image_note>0 then '\n' .. file.image_note else ''
        return result('Read image file [' .. file.mime_type .. ']' .. note,nil,false)
    end
    local selection=file.lines
    local total=selection.total
    if offset>total then return result(string.format('Offset %d is beyond end of file (%d lines total)',offset,total),nil,true) end
    local limit=natural(args.limit,total)
    local text=file.text
    -- File ranges include the empty line at EOF. The output budget counts only
    -- the lines in the selected text, excluding its terminal empty line.
    local count=if text=='' then 0 else selection.selected - (string.sub(text,-1)=='\n' and 1 or 0)
    local details
    if count>maxLines or #text>maxBytes then
        local firstLineExceedsLimit=selection.first_line_bytes>maxBytes
        local stop,shown,by=0,0,'lines'
        if firstLineExceedsLimit then
            by='bytes'
        else
            while shown<math.min(count,maxLines) do
                local last=(string.find(text,'\n',if shown==0 then 1 else stop+2,true) or #text+1)-1
                if last>maxBytes then by='bytes'; break end
                stop=last; shown+=1
            end
        end
        details={truncation={
            truncated=true,
            truncatedBy=by,
            totalLines=count,
            totalBytes=#text,
            outputLines=shown,
            outputBytes=stop,
            firstLineExceedsLimit=firstLineExceedsLimit,
            maxLines=maxLines,
            maxBytes=maxBytes,
        }}
        if firstLineExceedsLimit then
            text=string.format("[Line %d is %s, exceeds %s limit. Use bash: sed -n '%dp' %s | head -c %d]",offset,formatSize(selection.first_line_bytes),formatSize(maxBytes),offset,args.path,maxBytes)
        else
            local reason=if by=='bytes' then ' (' .. formatSize(maxBytes) .. ' limit)' else ''
            text=string.format('%s\n\n[Showing lines %d-%d of %d%s. Use offset=%d to continue.]',string.sub(text,1,stop),offset,offset+shown-1,total,reason,offset+shown)
        end
    elseif args.limit~=nil and limit<total-offset+1 then
        text=string.format('%s\n\n[%d more lines in file. Use offset=%d to continue.]',text,total-offset+1-limit,offset+limit)
    end
    return result(text,details,false)
end
