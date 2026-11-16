-- Newline-delimited JSON-RPC 2.0 over a child process's stdio.
--
-- Both adapters use this. It is liberal in what it accepts: malformed lines are
-- logged and skipped, responses to unknown IDs are ignored. vim.system()
-- callbacks run in libuv context, so everything is scheduled onto the main
-- loop and all handlers run there.

---@class boomer.RpcOpts
---@field cmd string[]
---@field cwd? string
---@field env? table<string, string>
---@field jsonrpc? boolean Send the "jsonrpc": "2.0" marker (ACP requires it, Codex omits it).
---@field notify fun(method: string, params: table)
---@field request fun(method: string, params: table, reply: fun(err: table?, result: any?), id: any)
---@field log fun(msg: string)
---@field exit fun(err: string) Called once when the process exits unexpectedly.

---@alias boomer.RpcCallback fun(err: { message: string }?, result: table)

local M = {}

---@class boomer.Rpc
---@field opts boomer.RpcOpts
---@field proc vim.SystemObj
---@field pending table<integer, boomer.RpcCallback> Outstanding requests by ID.
---@field closing? boolean No more traffic in either direction.
---@field exit? vim.SystemCompleted Set once the process has exited.
---@field stderr string Last 4 KiB of stderr, for error messages.
local Rpc = {}
Rpc.__index = Rpc

-- Default request timeout, and the delays before close() sends SIGTERM and
-- SIGKILL. Tests shorten them.
M.timeout_ms = 60000
M.term_ms = 1000
M.kill_ms = 3000

local windows = vim.fn.has('win32') == 1

local function stop(timer)
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

-- vim.system() adds `env` to Neovim's environment by exact name, but Windows
-- names are case-insensitive: `PATH` would duplicate the inherited `Path`
-- rather than replace it. Use the inherited spelling.
local function environment(env)
    if not env or not windows then
        return env
    end
    local names = {}
    for name in pairs(vim.fn.environ()) do
        names[name:upper()] = name
    end
    local out = {}
    for name, value in pairs(env) do
        out[names[name:upper()] or name] = value
    end
    return out
end

-- Spawn the process. Returns nil, err if it cannot be started.
---@param opts boomer.RpcOpts
---@return boomer.Rpc?, string?
function M.start(opts)
    local self = setmetatable({
        opts = opts,
        next_id = 1,
        pending = {},
        partial = {},
        stderr = '',
    }, Rpc)
    local ok, proc = pcall(vim.system, opts.cmd, {
        cwd = opts.cwd,
        env = environment(opts.env),
        stdin = true,
        stdout = function(_, data)
            if data then
                vim.schedule(function()
                    self:feed(data)
                end)
            end
        end,
        stderr = function(_, data)
            if data then
                self.stderr = (self.stderr .. data):sub(-4096)
            end
        end,
    }, function(result)
        vim.schedule(function()
            self:exited(result)
        end)
    end)
    if not ok then
        return nil, tostring(proc)
    end
    self.proc = proc
    return self
end

-- Split a chunk of stdout into lines; a trailing partial line waits for the
-- rest of it.
function Rpc:feed(data)
    local start = 1
    while true do
        local nl = data:find('\n', start, true)
        if not nl then
            break
        end
        self.partial[#self.partial + 1] = data:sub(start, nl - 1)
        local line = table.concat(self.partial)
        self.partial = {}
        start = nl + 1
        self:dispatch(line)
    end
    if start <= #data then
        self.partial[#self.partial + 1] = data:sub(start)
    end
end

-- Route one message: a request from the agent, a notification, or a response
-- to one of our requests.
function Rpc:dispatch(line)
    if self.closing or not line:find('%S') then
        return
    end
    local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(msg) ~= 'table' then
        self.opts.log('ignored malformed message: ' .. line:sub(1, 200))
        return
    end
    local params = type(msg.params) == 'table' and msg.params or {}
    if type(msg.method) == 'string' and msg.id ~= nil then
        -- The handler may reply later (permission prompts); only the first reply counts.
        local id, replied = msg.id, false
        self.opts.request(msg.method, params, function(err, result)
            if not replied then
                replied = true
                self:send({ id = id, error = err, result = not err and result or nil })
            end
        end, id)
    elseif type(msg.method) == 'string' then
        self.opts.notify(msg.method, params)
    elseif msg.id ~= nil and self.pending[msg.id] then
        local err = msg.error
        if err ~= nil then
            err = { message = type(err) == 'table' and tostring(err.message) or tostring(err) }
        end
        self.pending[msg.id](err, type(msg.result) == 'table' and msg.result or {})
    end
end

-- Returns false if the message could not be written.
function Rpc:send(msg)
    if self.closing then
        return false
    end
    msg.jsonrpc = self.opts.jsonrpc and '2.0' or nil
    return (pcall(self.proc.write, self.proc, vim.json.encode(msg) .. '\n'))
end

-- Empty params must still encode as a JSON object, not an array.
local function object(params)
    return params and next(params) and params or vim.empty_dict()
end

---@param method string
---@param params? table
function Rpc:notify(method, params)
    self:send({ method = method, params = object(params) })
end

-- cb(err, result) runs exactly once: with the response, on timeout, or when
-- the process exits. timeout_ms = false waits forever (prompt turns).
---@param method string
---@param params? table
---@param cb boomer.RpcCallback
---@param timeout_ms? integer|false
function Rpc:request(method, params, cb, timeout_ms)
    local id = self.next_id
    self.next_id = id + 1
    local timer
    self.pending[id] = function(err, result)
        self.pending[id] = nil
        stop(timer)
        cb(err, result)
    end
    if timeout_ms ~= false then
        timer = vim.defer_fn(function()
            if self.pending[id] then
                self.pending[id]({ message = method .. ' timed out' })
            end
        end, timeout_ms or M.timeout_ms)
    end
    if not self:send({ id = id, method = method, params = object(params) }) then
        -- Fail asynchronously, like every other outcome.
        vim.schedule(function()
            if self.pending[id] then
                self.pending[id]({ message = 'agent is not running' })
            end
        end)
    end
end

-- Process exit: fail outstanding requests with the exit code and the end of
-- stderr. Nothing is reported after close().
function Rpc:exited(result)
    self.exit = result
    stop(self.term_timer)
    stop(self.kill_timer)
    local err = 'agent exited with code ' .. result.code
    if result.signal ~= 0 then
        err = err .. ' (signal ' .. result.signal .. ')'
    end
    local tail = vim.trim(self.stderr)
    if tail ~= '' then
        err = err .. ':\n' .. tail
    end
    local pending = self.pending
    self.pending = {}
    if self.closing then
        return
    end
    self.closing = true
    self.opts.exit(err)
    for _, cb in pairs(pending) do
        cb({ message = err })
    end
end

-- Send `signal` to the agent. On Windows every signal is TerminateProcess,
-- which spares the agent's children. Agents installed by npm run behind a
-- .cmd shim, so the agent proper is a child of cmd.exe: it would survive,
-- keeping the pipes (and so the exit callback) open. End the whole tree.
function Rpc:kill(signal)
    if windows and not self.exit then
        local ok = pcall(
            vim.system,
            { 'taskkill', '/pid', tostring(self.proc.pid), '/t', '/f' },
            { text = true },
            function(result)
                if result.code ~= 0 then
                    pcall(self.proc.kill, self.proc, signal)
                end
            end
        )
        if ok then
            return
        end
    end
    pcall(self.proc.kill, self.proc, signal)
end

-- Stop the agent: close its stdin and escalate to SIGTERM, then SIGKILL, if it
-- ignores EOF. Callbacks stop immediately. `force` sends SIGTERM right away
-- (used when Neovim is exiting and cannot wait).
---@param force? boolean
function Rpc:close(force)
    if self.exit then
        return
    end
    if not self.closing then
        self.closing = true
        self.pending = {}
        pcall(self.proc.write, self.proc, nil)
        self.term_timer = vim.defer_fn(function()
            self:kill('sigterm')
        end, M.term_ms)
        self.kill_timer = vim.defer_fn(function()
            self:kill('sigkill')
        end, M.kill_ms)
    end
    if force then
        self:kill('sigterm')
    end
end

return M
