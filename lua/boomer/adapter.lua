-- What the protocol adapters (boomer.codex and boomer.acp) share: starting
-- the agent process, ending a turn and tracking permission requests.
--
-- An adapter class made by class() inherits these methods and defines
-- notification(), server_request(), settle_requests() (answer the open
-- requests before a cancel or after the turn) and reset_turn() (clear its
-- per-turn state).
local Rpc = require('boomer.rpc')
local M = {}

---@class boomer.Adapter : boomer.Client
---@field rpc boomer.Rpc
---@field on boomer.Callbacks
---@field profile boomer.Profile
---@field turn? { cb: fun(err: table?, status: string?) } The running turn.
---@field requests table<any, boomer.Permission> Open permission requests by RPC ID.
---@field notification fun(self, method: string, params: table?)
---@field server_request fun(self, method: string, params: table?, reply: function, id: any)
---@field settle_requests fun(self)
---@field reset_turn fun(self)
local Adapter = {}
Adapter.__index = Adapter

-- A new adapter class inheriting the shared methods.
function M.class()
    local class = setmetatable({}, Adapter)
    class.__index = class
    return class
end

-- A new adapter of `class` (with the fields in `self`) running its agent
-- process; nil, err if it cannot start. `cmd` is the command line; `jsonrpc`
-- as in boomer.RpcOpts. When the agent exits, the running turn fails.
---@generic T : boomer.Adapter
---@param class T
---@param self table
---@param cmd string[]
---@param jsonrpc? boolean
---@return T?, string?
function M.spawn(class, self, cmd, jsonrpc)
    self.requests = {}
    setmetatable(self, class)
    self:reset_turn()
    local on = self.on
    local rpc, err = Rpc.start({
        cmd = cmd,
        cwd = self.profile.cwd,
        env = self.profile.env,
        jsonrpc = jsonrpc,
        notify = function(method, params)
            self:notification(method, params)
        end,
        request = function(method, params, reply, id)
            self:server_request(method, params, reply, id)
        end,
        log = on.error,
        exit = function(msg)
            on.exit(msg)
            self:finish({ message = msg })
        end,
    })
    if not rpc then
        return nil, err
    end
    self.rpc = rpc
    return self
end

function Adapter:close(force)
    self.rpc:close(force)
end

-- End the running turn, if any: settle its open requests, then run its
-- callback.
function Adapter:finish(err, status)
    local turn = self.turn
    if turn then
        self.turn = nil
        self:reset_turn()
        self:settle_requests()
        turn.cb(err, status)
    end
end

-- Show permission request `req`, sent as RPC request `id`; reply() answers
-- the agent once, when the user or the adapter settles it.
---@param id any
---@param req boomer.Permission Without its `reply`.
---@param reply fun(err: table?, result: any)
function Adapter:ask(id, req, reply)
    req.reply = function(result)
        if not req.done then
            req.done = true
            self.requests[id] = nil
            reply(nil, result)
        end
    end
    self.requests[id] = req
    self.on.permission(req)
end

return M
