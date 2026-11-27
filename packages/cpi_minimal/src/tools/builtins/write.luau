local function execute(args)
    host.call('files.write',{path=path(args.path),content=args.content})
    return result('Successfully wrote to ' .. args.path,nil,false)
end
