-- main.lua: Kaminec-Spike CLI -- thin wrapper around planner + adapters
-- usage:
--   lua src/main.lua versions
--   lua src/main.lua plan 1.21.8 [--dir .minecraft] [--offline]
--   lua src/main.lua download 1.21.8 [--dir .minecraft] [--repair|--verify]
--   lua src/main.lua launch 1.21.8 [--dir .minecraft] [--java java] [--name Steve] [--dry-run]
-- env:
--   KAMINEC_PROXY  http(s) proxy for curl (falls back to HTTPS_PROXY / HTTP_PROXY)

-- Resolve modules relative to this file, so the CLI works from any CWD.
-- Files are grouped by role (core/net/auth/accounts/host/vendor) while the
-- Lua module names stay short; all role directories are on package.path.
do
    local script = (arg and arg[0]) or "src/main.lua"
    script = script:gsub("\\", "/")
    local root = script:match("^(.*)/") or "src"
    local paths = {}
    for _, dir in ipairs({ root, root .. "/core", root .. "/net", root .. "/auth",
                            root .. "/accounts", root .. "/host", root .. "/vendor" }) do
        paths[#paths + 1] = dir .. "/?.lua"
    end
    package.path = table.concat(paths, ";") .. ";" .. package.path
end

local util = require("util")
local json = require("json")
local adapters = require("adapters")
local planner = require("planner")
local launcher = require("launcher")
local assets = require("assets")
local account = require("account")
local download = require("download")
local natives = require("natives")
local http = require("http")
local accounts = require("accounts")
local auth = require("login")
local graph = require("graph_setup")
local importer = require("accounts_import")

local function parse(argv)
    local opts, rest = {}, {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a:sub(1, 2) == "--" then
            local key = a:sub(3)
            local nxt = argv[i + 1]
            if nxt and nxt:sub(1, 2) ~= "--" then
                opts[key] = nxt
                i = i + 2
            else
                opts[key] = true
                i = i + 1
            end
        else
            rest[#rest + 1] = a
            i = i + 1
        end
    end
    return opts, rest
end

local function workdir_of(opts)
    return util.abs(opts.dir or ".minecraft")
end

-- Azure application (public client) id for the device-code flow.
-- Priority: --client-id > KAMINEC_MSA_CLIENT_ID > <workdir>/msa.json
local function client_id_of(opts, workdir)
    if opts["client-id"] and opts["client-id"] ~= true then return opts["client-id"] end
    local env = os.getenv("KAMINEC_MSA_CLIENT_ID")
    if env and env ~= "" then return env end
    local path = util.join(workdir, "msa.json")
    if util.exists(path) then
        local ok, data = pcall(json.decode, util.read(path))
        if ok and type(data) == "table" and data.client_id and data.client_id ~= "" then
            return data.client_id
        end
    end
    return nil
end

-- Load a stored Microsoft account and refresh its Minecraft token if needed.
local function load_account(opts, workdir)
    local store = accounts.load(accounts.path(workdir))
    local acct = accounts.find(store, opts.account)
    if not acct then error("账号不存在: " .. tostring(opts.account)) end
    local cid = client_id_of(opts, workdir) or acct.client_id
    if acct.auth_mode ~= "imported" then
        if not cid or cid == "" then
            error("缺少 Azure client id（--client-id / KAMINEC_MSA_CLIENT_ID / "
                .. util.join(workdir, "msa.json") .. "）")
        end
    end
    local resolved, err = auth.resolve(http, acct, cid)
    if not resolved then error(err) end
    accounts.save(accounts.path(workdir), store)
    return acct
end

local function summarize(plan)
    print(string.format("  version: %s (docs=%d%s)", plan.version_id, plan.docs,
        plan.legacy_format and ", legacy" or ""))
    print(string.format("  main class: %s", plan.main_class))
    print(string.format("  classpath entries: %d", #plan.classpath))
    print(string.format("  missing downloads: %d", #plan.downloads))
    if plan.natives and #plan.natives > 0 then
        print(string.format("  natives archives: %d", #plan.natives))
    end
    if plan.assets.index_id then
        print(string.format("  assets index: %s (%s)", plan.assets.index_id,
            plan.assets.index_present and "present" or "missing"))
    end
    if plan.java_version then
        print(string.format("  java required: %s (major %s)",
            tostring(plan.java_version.component), tostring(plan.java_version.majorVersion)))
    end
    for _, w in ipairs(plan.warnings) do
        print("  warning: " .. w)
    end
end

local function ensure_assets(host, workdir, plan, opts)
    if opts["no-assets"] then return end
    if not plan.assets or not plan.assets.index_path then return end
    if not host.exists(plan.assets.index_path) then return end
    local index = json.decode(host.read(plan.assets.index_path))
    if opts.offline then
        local missing = assets.missing(workdir, index)
        if #missing > 0 then
            error(string.format("offline: %d asset object(s) missing", #missing))
        end
        return
    end
    assets.ensure(workdir, index, opts)
end

local function build_plan(host, opts, rest, with_downloads)
    local workdir = workdir_of(opts)
    local id = rest[1] or "latest"
    local acct
    if opts.account then
        acct = load_account(opts, workdir)
        opts.name = acct.name
        opts.uuid = acct.uuid
        opts.access_token = acct.access_token
        opts.user_type = acct.user_type or "msa"
        opts.xuid = acct.xuid
        opts.clientid = acct.client_id
    else
        acct = account.offline(opts.name or "Steve")
        opts.name = acct.name
        opts.uuid = acct.uuid
        opts.access_token = acct.access_token
        opts.user_type = acct.user_type
        opts.xuid = nil
        opts.clientid = nil
    end

    -- --repair / --verify need existing files in the plan so they can be checked
    if with_downloads and (opts.repair or opts.verify) then
        opts.include_existing = true
    end

    local plan = planner.build(host, workdir, id, opts)
    summarize(plan)

    if with_downloads then
        if opts.offline and #plan.downloads > 0 then
            error(string.format("offline: %d file(s) missing; run without --offline to download", #plan.downloads))
        end
        local stats = download.apply(host, plan, { repair = opts.repair, verify = opts.verify })
        print(string.format("  download: %d new, %d skipped, %d mismatched, %d failed",
            stats.downloaded, stats.skipped, stats.mismatched, stats.failed))
        for _, w in ipairs(stats.warnings) do print("  warning: " .. w) end
        if stats.failed > 0 then
            error(string.format("%d download(s) failed", stats.failed))
        end
        ensure_assets(host, workdir, plan, opts)
        if plan.natives and #plan.natives > 0 then
            local extracted, missing = natives.ensure(host, plan)
            print(string.format("  natives: %d extracted, %d missing", extracted, #missing))
            if #missing > 0 then
                error(string.format("%d natives archive(s) missing", #missing))
            end
        end
        -- the refresh must only list files that are still missing
        opts.include_existing = nil
        plan = planner.build(host, workdir, id, opts)
        print(string.format("  remaining downloads: %d", #plan.downloads))
    end
    return plan, acct
end

local function cmd_versions(opts)
    local host = adapters.cli()
    local m = planner.manifest(host, workdir_of(opts), opts)
    print(string.format("latest release: %s   latest snapshot: %s", m.latest.release, m.latest.snapshot))
    local n = 0
    for _, v in ipairs(m.versions) do
        if v.type == "release" then
            print(string.format("  %-16s %s", v.id, v.releaseTime))
            n = n + 1
            if n >= 10 then break end
        end
    end
end

local function redact_plan_args(plan, token)
    if not token or token == "" then return plan end
    local args = plan.game_args or {}
    for i = 1, #args - 1 do
        if args[i] == "--accessToken" and args[i + 1] == token then
            args[i + 1] = "***"
        end
    end
    return plan
end

local function cmd_plan(opts, rest)
    local host = adapters.cli()
    local plan = build_plan(host, opts, rest, false)
    redact_plan_args(plan, opts.access_token)
    local out = json.encode(plan)
    if opts.out then
        util.write(util.abs(opts.out), out .. "\n")
        print("plan written to " .. util.abs(opts.out))
    else
        print("")
        print(out)
    end
end

local function cmd_download(opts, rest)
    local host = adapters.cli()
    build_plan(host, opts, rest, true)
    print("download complete")
end

local function cmd_launch(opts, rest)
    local host = adapters.cli()
    -- dry-run must stay offline: never download just to print the command
    local plan = build_plan(host, opts, rest, not opts["dry-run"])

    util.mkdir(plan.natives_dir)
    util.mkdir(plan.game_dir)
    util.mkdir(plan.assets_dir)

    local cmd = launcher.build(opts.java or "java", plan.jvm_args, plan.main_class, plan.game_args)
    print(string.format("  account: %s / %s (%s)", opts.name, opts.uuid,
        opts.account and "microsoft" or "offline"))
    if opts["dry-run"] then
        print("")
        print(launcher.redact(cmd))
        return
    end
    local logpath = util.join(workdir_of(opts), "logs", "kaminec-spike.log")
    util.mkdir(util.dirname(logpath))
    print("launching ...")
    local code = launcher.run(cmd, workdir_of(opts), plan.game_dir, logpath)
    print("")
    print(string.format("exit code: %s", tostring(code)))
    os.exit(code)
end

local function cmd_login(opts)
    local workdir = workdir_of(opts)
    local acct, err
    if opts.live then
        -- no Azure registration: live.com device code + public Xbox client id
        acct, err = auth.live_device_login(http)
    else
        local cid = client_id_of(opts, workdir)
        if not cid then
            error("缺少 Azure client id：用 --client-id、环境变量 KAMINEC_MSA_CLIENT_ID，"
                .. "或写入 " .. util.join(workdir, "msa.json") .. "；"
                .. "如果不想注册 Azure 应用，用 login --live（免注册设备码）")
        end
        if opts["device-code"] then
            acct, err = auth.device_login(http, cid)
        else
            acct, err = auth.browser_login(http, cid, {
                port = tonumber(opts.port),
                timeout = tonumber(opts.timeout),
            })
        end
    end
    if not acct then error(err) end
    local store = accounts.load(accounts.path(workdir))
    accounts.upsert(store, acct)
    accounts.save(accounts.path(workdir), store)
    print("")
    print(string.format("登录成功: %s (%s)", acct.name, acct.uuid))
    print("账号已保存: " .. accounts.path(workdir))
end

-- Create a personal Azure application via Microsoft Graph (no Azure portal).
local function cmd_setup_app(opts)
    local workdir = workdir_of(opts)
    local app, err = graph.setup(http, { name = opts.name or "Kaminec-Spike" })
    if not app then error(err) end
    local path = util.join(workdir, "msa.json")
    util.write(path, json.encode({ client_id = app.app_id }) .. "\n")
    print("")
    print("已创建 Azure 应用: " .. app.app_id)
    print("client id 已写入: " .. path)
    print("现在可以运行: lua src/main.lua login --dir " .. tostring(opts.dir or ".minecraft"))
end

-- Import a Minecraft access token from the official launcher.
local function cmd_import(opts)
    local workdir = workdir_of(opts)
    local found = importer.scan()
    if #found == 0 then
        print("没有找到官方启动器的账号文件（%APPDATA%\\.minecraft\\launcher_accounts.json）")
        print("请先用官方启动器登录一次，再重试。")
        return
    end
    if not opts.yes then
        print("将读取官方启动器保存的 Minecraft access token（约 24 小时有效）。")
        print("只保存 access token，不保存 refresh token，也不会自动上传。")
        print(string.format("检测到 %d 个账号：", #found))
        for _, acct in ipairs(found) do
            print("  " .. acct.name .. " (" .. tostring(acct.uuid) .. ")")
        end
        print("确认导入请加 --yes，例如：")
        print("  lua src/main.lua import --dir " .. tostring(opts.dir or ".minecraft") .. " --yes")
        return
    end
    local store = accounts.load(accounts.path(workdir))
    for _, acct in ipairs(found) do
        accounts.upsert(store, acct)
        local exp = acct.expires_at and os.date("%Y-%m-%d %H:%M", acct.expires_at) or "未知"
        print(string.format("导入 %s (%s) 来源=%s 过期=%s",
            acct.name, tostring(acct.uuid), tostring(acct.imported_from), exp))
    end
    accounts.save(accounts.path(workdir), store)
    print("已保存到 " .. accounts.path(workdir))
    print("现在可以: launch <version> --account <玩家名>")
end

local function cmd_accounts(opts)
    local store = accounts.load(accounts.path(workdir_of(opts)))
    local names = accounts.list(store)
    if #names == 0 then
        print("(没有已保存账号)")
        return
    end
    for _, name in ipairs(names) do
        local a = store.accounts[name]
        print(string.format("%s  %s  %s", name, tostring(a.uuid), tostring(a.user_type or "msa")))
    end
end

local cmds = {
    versions = cmd_versions,
    login = cmd_login,
    ["setup-app"] = cmd_setup_app,
    import = cmd_import,
    accounts = cmd_accounts,
    plan = cmd_plan,
    download = cmd_download,
    launch = cmd_launch,
}

local function main(argv)
    local opts, rest = parse(argv)
    local name = rest[1]
    local fn = name and cmds[name]
    if not fn then
        print("Kaminec-Spike -- minimal Lua Minecraft launcher")
        print("usage: lua src/main.lua <versions|login|setup-app|import|accounts|plan|download|launch> [args]")
        print("")
        print("examples:")
        print("  lua src/main.lua import --dir .minecraft --yes")
        print("  lua src/main.lua setup-app --dir .minecraft")
        print("  lua src/main.lua login --dir .minecraft")
        print("  lua src/main.lua login --dir .minecraft --client-id <azure-app-id>")
        print("  lua src/main.lua versions")
        print("  lua src/main.lua plan 1.20.1-forge-47.3.0 --dir .minecraft")
        print("  lua src/main.lua download 1.21.8 --dir .minecraft --repair")
        print("  lua src/main.lua launch 1.21.8 --dir .minecraft --account Steve")
        print("  lua src/main.lua launch 1.21.8 --dir .minecraft --name Steve")
        os.exit(1)
    end
    table.remove(rest, 1)
    local ok, err = pcall(fn, opts, rest)
    if not ok then
        print("error: " .. tostring(err):gsub("^[^:]+:%d+: ", ""))
        os.exit(1)
    end
end

main(arg)
