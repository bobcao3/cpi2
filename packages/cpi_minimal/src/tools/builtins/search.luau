local function execute(args)
    local request = table.clone(args)
    request.path = path(if args.path == nil or args.path == '' then '.' else args.path)
    local response = host.call(endpoint, request)
    return result(response.text, if type(response.details) == 'table' then response.details else nil, response.is_error)
end
