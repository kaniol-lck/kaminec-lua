-- plugin.lua: embeddable Kaminec-Spike API (api_version = 1).
--
-- A host (modmanager, a Python/Rust/C++ wrapper, another Lua app) provides a
-- table of callbacks; this module never calls os.execute/io.popen itself, so it
-- can run inside a sandboxed or GUI process.
--
-- Required host callbacks:
--   exists(path) -> boolean
--   read(path) -> string
--   write(path, data)
--   mkdir(path)
--   size(path) -> number (-1 when missing)
--   fetch(url, path, opts) -> path            (opts.resume/sha1/size)
--   log(message)
--
-- Optional host callbacks:
--   extract_zip(zip, dest)                     legacy natives
--   ensure_assets(index_path, assets_dir)      asset objects (host downloader)
--   spawn({program,args,cwd,workdir}) -> ok,err
--
-- Usage:
--   local plugin = require("plugin").new(host, { workdir = "D:/game/.minecraft" })
--   local plan = plugin:build_plan("1.20.1-forge-47.3.0", {offline=true})
--   plugin:ensure(plan)
--   local cmd = plugin:command(plan, {java="java"})
--   plugin:run(cmd)
local planner = require("planner")
local download = require("download")
local natives = require("natives")
local accounts = require("accounts")
local importer = require("accounts_import")
local auth = require("login")
local account = require("account")

local M = {}

M.API_VERSION = 1
M.VERSION = "0.1.0"

local REQUIRED = { "exists", "read", "write", "mkdir", "size", "fetch", "log" }

local function check_host(host)
    if type(host) ~= "table" then error("host must be a table of callbacks") end
    for _, name in ipairs(REQUIRED) do
        if type(host[name]) ~= "function" then
            error("host." .. name .. " is required")
        end
    end
end

function M.new(host, opts)
    check_host(host)
    opts = opts or {}
    if not opts.workdir then error("opts.workdir is required (absolute path)") end

    local self = {
        host = host,
        opts = opts,
        api_version = M.API_VERSION,
        version = M.VERSION,
    }

    local function merged(extra)
        local o = {}
        for k, v in pairs(self.opts) do o[k] = v end
        for k, v in pairs(extra or {}) do o[k] = v end
        return o
    end

    -- Build a LaunchPlan. Pure parsing + filesystem reads; no network unless
    -- opts.offline is false and a version json is missing locally.
    function self:build_plan(version_id, options)
        local o = merged(options)
        return planner.build(host, o.workdir, version_id, o)
    end

    -- Download missing libraries/client/asset index, then extract legacy
    -- natives. Asset objects are delegated to host.ensure_assets when present.
    function self:ensure(plan, options)
        local o = merged(options)
        local stats = download.apply(host, plan, {
            repair = o.repair,
            verify = o.verify,
        })
        local natives_stats = { extracted = 0, missing = {} }
        if plan.natives and #plan.natives > 0 then
            if type(host.extract_zip) ~= "function" then
                error("host.extract_zip is required for legacy natives")
            end
            local extracted, missing = natives.ensure(host, plan)
            natives_stats = { extracted = extracted, missing = missing }
        end
        if type(host.ensure_assets) == "function" and plan.assets
            and plan.assets.index_path and host.exists(plan.assets.index_path) then
            host.ensure_assets(plan.assets.index_path, plan.assets_dir)
        end
        return { download = stats, natives = natives_stats }
    end

    -- Pure command description (no shell quoting). The host decides how to
    -- spawn it; the access token is present in args and must not be logged.
    function self:command(plan, options)
        local o = options or {}
        local args = {}
        for _, a in ipairs(plan.jvm_args or {}) do args[#args + 1] = a end
        args[#args + 1] = plan.main_class
        for _, a in ipairs(plan.game_args or {}) do args[#args + 1] = a end
        return {
            program = o.java or self.opts.java or "java",
            args = args,
            cwd = plan.game_dir,
            workdir = self.opts.workdir,
        }
    end

    -- Convenience wrapper for hosts that provide spawn.
    function self:run(plan, options)
        local cmd = self:command(plan, options)
        if type(host.spawn) ~= "function" then
            return nil, "host.spawn is not provided; use plugin:command() instead"
        end
        return host.spawn(cmd)
    end

    -- Account helpers (host filesystem only; no process/UI).
    function self:offline_account(name)
        return account.offline(name or self.opts.name or "Steve")
    end

    function self:load_account(name, client_id)
        local store = accounts.load(accounts.path(self.opts.workdir))
        local acct = accounts.find(store, name)
        if not acct then return nil, "账号不存在: " .. tostring(name) end
        local cid = client_id or self.opts.client_id or acct.client_id
        if acct.auth_mode ~= "imported" then
            if not cid or cid == "" then
                return nil, "缺少 Azure client id"
            end
        end
        local ok, err = auth.resolve(self.opts.httpc or {}, acct, cid)
        if not ok then return nil, err end
        accounts.save(accounts.path(self.opts.workdir), store)
        return acct
    end

    function self:import_official_accounts()
        return importer.scan()
    end

    function self:list_accounts()
        local store = accounts.load(accounts.path(self.opts.workdir))
        return store, accounts.list(store)
    end

    return self
end

return M
