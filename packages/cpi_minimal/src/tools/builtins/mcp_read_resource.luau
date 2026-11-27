local function execute(args)
    return host.call('mcp.resources.read', {server=args.server, uri=args.uri})
end
