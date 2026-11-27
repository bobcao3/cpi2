local function fuzzy(text)
    local normalized=host.call('text.normalize_nfkc',{text=text}).text
    local out,last={},0
    for _,cp in utf8.codes(normalized) do
        local ch=cp
        if cp>=0x2018 and cp<=0x201b then ch=39
        elseif cp>=0x201c and cp<=0x201f then ch=34
        elseif (cp>=0x2010 and cp<=0x2015) or cp==0x2212 then ch=45
        elseif cp==0xa0 or (cp>=0x2002 and cp<=0x200a) or cp==0x202f or cp==0x205f or cp==0x3000 then ch=32 end
        if ch==10 then for i=#out,last+1,-1 do out[i]=nil end end
        table.insert(out,utf8.char(ch))
        local space=(cp>=9 and cp<=13) or cp==32 or cp==0xa0 or cp==0x1680 or (cp>=0x2000 and cp<=0x200a) or cp==0x2028 or cp==0x2029 or cp==0x202f or cp==0x205f or cp==0x3000 or cp==0xfeff
        if ch==10 or not space then last=#out end
    end
    for i=#out,last+1,-1 do out[i]=nil end
    return table.concat(out)
end
local function apply(base,matches,offset)
    local out,at={},1
    for _,m in ipairs(matches) do
        table.insert(out,string.sub(base,at,m.start-offset-1))
        table.insert(out,m.replacement)
        at=m.stop-offset
    end
    table.insert(out,string.sub(base,at))
    return table.concat(out)
end
local function originalMatches(original,base,matches)
    local old,normalized=lineStarts(original),lineStarts(base)
    assert(#old==#normalized,'FuzzyNormalizationChangedLineCount')
    local plan,i={},1
    while i<=#matches do
        local first=lineAt(normalized,matches[i].start)
        local last=lineAt(normalized,matches[i].stop-1)+1
        local next=i+1
        while next<=#matches and lineAt(normalized,matches[next].start)<last do
            last=math.max(last,lineAt(normalized,matches[next].stop-1)+1)
            next+=1
        end
        local group={}
        for n=i,next-1 do table.insert(group,matches[n]) end
        local allExact=true
        for _,m in ipairs(group) do if not m.exact then allExact=false end end
        local replacement
        if allExact then
            local raw={}
            for _,m in ipairs(group) do table.insert(raw,{start=m.original_start,stop=m.original_stop,replacement=m.replacement}) end
            replacement=apply(string.sub(original,old[first],old[last]-1),raw,old[first]-1)
        else replacement=apply(string.sub(base,normalized[first],normalized[last]-1),group,normalized[first]-1) end
        table.insert(plan,{start=old[first],stop=old[last],replacement=replacement})
        i=next
    end
    return plan
end
local function firstChangedLine(old,new)
    local line=1
    for i=1,math.min(#old,#new) do
        local byte=string.byte(old,i)
        if byte~=string.byte(new,i) then break end
        if byte==10 then line+=1 end
    end
    return line
end
local function prepareEdit(args)
    local edits=args.edits or {}
    if edits.oldText then edits={edits} end
    if args.oldText and args.newText then table.insert(edits,{oldText=args.oldText,newText=args.newText}) end
    if #edits==0 then return nil,result('Edit tool input is invalid. edits must contain at least one replacement.',nil,true) end
    local function empty(index)
        return nil,result((if #edits==1 then 'oldText' else string.format('edits[%d].oldText',index-1)) .. ' must not be empty in ' .. args.path .. '.',nil,true)
    end
    local function missing(index)
        if #edits==1 then return nil,result('Could not find the exact text in ' .. args.path .. '. The old text must match exactly including all whitespace and newlines.',nil,true) end
        return nil,result(string.format('Could not find edits[%d] in %s. The oldText must match exactly including all whitespace and newlines.',index-1,args.path),nil,true)
    end
    local function duplicate(index,count)
        if #edits==1 then return nil,result(string.format('Found %d occurrences of the text in %s. The text must be unique. Please provide more context to make it unique.',count,args.path),nil,true) end
        return nil,result(string.format('Found %d occurrences of edits[%d] in %s. Each oldText must be unique. Please provide more context to make it unique.',count,index-1,args.path),nil,true)
    end
    local function overlap(a,b)
        return nil,result(string.format('edits[%d] and edits[%d] overlap in %s. Merge them into one edit or target disjoint regions.',a.index,b.index,args.path),nil,true)
    end
    for index,e in ipairs(edits) do
        e.oldText=lf(e.oldText); e.newText=lf(e.newText)
        if #e.oldText==0 then return empty(index) end
    end
    local location=path(args.path)
    local file=host.call('files.read',{path=location})
    assert(type(file.text)=='string','Edit requires valid UTF-8 text. The file was not changed.')
    local raw=file.text
    local bom=string.sub(raw,1,3)=='\239\187\191'
    local text=bom and string.sub(raw,4) or raw
    local newline=string.find(text,'\n',1,true)
    local crlf=newline and newline>1 and string.sub(text,newline-1,newline-1)=='\r'
    local original=lf(text)
    local function locate(haystack,needle)
        local count,at,first,last=0,1,nil,nil
        while true do
            local start,stop=string.find(haystack,needle,at,true)
            if not start then return count,first,last end
            count+=1; at=stop+1
            if not first then first,last=start,stop+1 end
        end
    end
    local exacts,exactIndices,needsFuzzy={},{},false
    for index,e in ipairs(edits) do
        local count,start,stop=locate(original,e.oldText)
        if count>1 then return duplicate(index,count) end
        if count==1 then
            exactIndices[index]=true
            table.insert(exacts,{start=start,stop=stop,replacement=e.newText,index=index-1,original_start=start,original_stop=stop,exact=true})
        else needsFuzzy=true end
    end
    local matches,base=exacts,original
    if needsFuzzy then
        local normalized=fuzzy(original)
        local prefix='\000exact'
        while string.find(original,prefix,1,true) or string.find(normalized,prefix,1,true) do prefix ..= '_' end
        table.sort(exacts,function(a,b) return a.start<b.start end)
        for i=2,#exacts do if exacts[i-1].stop>exacts[i].start then return overlap(exacts[i-1],exacts[i]) end end
        local masks={}
        for _,m in ipairs(exacts) do
            local newlines=0
            for at=m.start,m.stop-1 do if string.byte(original,at)==10 then newlines+=1 end end
            m.token=prefix .. tostring(m.index) .. '[' .. string.rep('\n',newlines) .. ']'
            table.insert(masks,{start=m.start,stop=m.stop,replacement=m.token})
        end
        base=#exacts>0 and fuzzy(apply(original,masks,0)) or normalized
        matches={}
        for _,m in ipairs(exacts) do
            local first,last=string.find(base,m.token,1,true)
            assert(first,'ExactEditMarkerLost')
            table.insert(matches,{start=first,stop=last+1,replacement=m.replacement,index=m.index,exact=true,original_start=m.original_start,original_stop=m.original_stop})
        end
        for index,e in ipairs(edits) do
            if not exactIndices[index] then
                local needle=fuzzy(e.oldText)
                if #needle==0 then return empty(index) end
                local count=locate(normalized,needle)
                if count==0 then return missing(index) end
                if count>1 then return duplicate(index,count) end
                local first,last=string.find(base,needle,1,true)
                if not first then return missing(index) end
                table.insert(matches,{start=first,stop=last+1,replacement=e.newText,index=index-1})
            end
        end
    end
    table.sort(matches,function(a,b) return a.start<b.start end)
    for i=2,#matches do
        if matches[i-1].stop>matches[i].start then return overlap(matches[i-1],matches[i]) end
    end
    local plan=if needsFuzzy then originalMatches(original,base,matches) else matches
    local updated=apply(original,plan,0)
    if updated==original then
        local reason=if #edits==1 then 'The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.' else 'The replacements produced identical content.'
        return nil,result('No changes made to ' .. args.path .. '. ' .. reason,nil,true)
    end
    local output=crlf and replace(updated,'\n','\r\n') or updated
    if bom then output='\239\187\191' .. output end
    local message=string.format('Successfully replaced %d block(s) in %s.',#edits,args.path)
    if jsonStringBytes(message)>editResultTextBudget then
        message=string.format('Successfully replaced %d block(s).',#edits)
    end
    local shown,diff,changed=pcall(editDisplayDiff,original,updated,plan,message)
    local details={firstChangedLine=if shown and changed then changed else firstChangedLine(original,updated)}
    if shown and diff and diff~='' then details.diff=diff
    else details.diffOmitted=true end
    return {
        write={path=location,content=output,expected_sha256=file.sha256,create_parents=false},
        result=result(message,details,false),
    }
end
