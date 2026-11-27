local function execute(args)
    return host.call('mcp.resources.list', {server=args.server, cursor=args.cursor or ''})
end
