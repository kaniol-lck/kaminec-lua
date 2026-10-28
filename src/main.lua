-- main.lua: Kaminec-Lua CLI -- thin wrapper around planner + adapters
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
local profile = require("profile")
local java = require("java")
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

-- Apply a profile's root/paths/settings to the CLI options. Explicit CLI
-- flags win over profile settings, which win over profiles.json defaults.
local function resolve_profile(opts)
    if not opts.profile or opts.profile == true then return end
    local store = profile.load(workdir_of(opts))
    local p = profile.find(store, opts.profile)
    if not p then
        error("profile 不存在: " .. tostring(opts.profile) .. "（用 profile list 查看）")
    end
    local eff = profile.merge(store.defaults, p.settings)
    if p.root and p.root ~= "" then opts.dir = p.root end
    opts.game_dir = p.game_dir
    opts.natives_dir = p.natives_dir
    opts.version = p.version
    local explicit_java = opts.java
    opts.memory = opts.memory or eff.memory
    opts.java = opts.java or eff.java
    if opts.java == "auto" then opts.java_auto = true end
    if not explicit_java then opts.java_auto = opts.java_auto or eff.java_auto end
    opts.account = opts.account or eff.account
    opts.name = opts.name or eff.username
    opts._profile = p
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
    local id = rest[1] or opts.version or "latest"
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
    local required_java = plan.java_version and tonumber(plan.java_version.majorVersion)
    if required_java then
        if not opts.java or opts.java == "auto" or opts.java_auto then
            local selected = java.select(required_java)
            if selected then
                opts.java = selected.path
                print("  java: " .. java.describe(selected))
            else
                opts.java_mismatch = "没有找到 Java " .. tostring(required_java) .. "；请用 --java 指定"
                print("  warning: " .. opts.java_mismatch)
            end
        else
            local ok, info = java.validate(opts.java, required_java)
            if not ok then
                opts.java_mismatch = info
                print("  warning: " .. info)
            else
                print("  java: " .. java.describe(info))
            end
        end
    end
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

local function relpath(root, path)
    local r = tostring(root):gsub("\\", "/"):gsub("/+$", "")
    local p = tostring(path):gsub("\\", "/")
    if p:sub(1, #r + 1) == r .. "/" then return p:sub(#r + 2) end
    return p
end

local function collect_download_tasks(plan, workdir)
    local tasks = {}
    for _, d in ipairs(plan.downloads or {}) do
        if d.url and d.url ~= "" then
            tasks[#tasks + 1] = {
                url = d.url,
                path = relpath(workdir, d.path),
                size = d.size,
                sha1 = d.sha1,
                kind = d.kind,
                name = d.name,
            }
        end
    end
    if plan.assets and plan.assets.index_path and util.exists(plan.assets.index_path) then
        local ok, index = pcall(json.decode, util.read(plan.assets.index_path))
        if ok and type(index) == "table" then
            for _, o in ipairs(assets.missing(workdir, index)) do
                tasks[#tasks + 1] = {
                    url = "https://resources.download.minecraft.net/" .. o.hash:sub(1, 2) .. "/" .. o.hash,
                    path = relpath(workdir, o.path),
                    size = o.size,
                    sha1 = o.hash,
                    kind = "asset",
                    name = o.hash,
                }
            end
        end
    end
    return tasks
end

local function export_tasks(opts, rest, format)
    local host = adapters.cli()
    local plan = build_plan(host, opts, rest, false)
    local workdir = workdir_of(opts)
    local tasks = collect_download_tasks(plan, workdir)
    local target = opts["export-" .. format]
    if target == true then
        target = util.join(workdir, "aria2-tasks.txt")
        if format == "json" then target = util.join(workdir, "aria2-tasks.json") end
    end
    target = util.abs(target)
    if format == "json" then
        util.write(target, json.encode({ schema = 1, root = workdir, tasks = tasks }) .. "\n")
    else
        local lines = {
            "# generated by Kaminec-Lua; run: aria2c -i this-file -j 16 -c",
            "dir=" .. workdir:gsub("\\", "/"),
            "continue=true",
            "auto-file-renaming=false",
        }
        for _, t in ipairs(tasks) do
            lines[#lines + 1] = "out=" .. t.path
            lines[#lines + 1] = "url=" .. t.url
            if t.sha1 and t.sha1 ~= "" then lines[#lines + 1] = "checksum=sha-1=" .. t.sha1 end
        end
        util.write(target, table.concat(lines, "\n") .. "\n")
    end
    print(string.format("exported %d task(s) to %s", #tasks, target))
end

local function cmd_download(opts, rest)
    if opts["export-aria2"] or opts["export-json"] then
        if opts["export-aria2"] then export_tasks(opts, rest, "aria2") end
        if opts["export-json"] then export_tasks(opts, rest, "json") end
        return
    end
    local host = adapters.cli()
    build_plan(host, opts, rest, true)
    print("download complete")
end

local function cmd_launch(opts, rest)
    local host = adapters.cli()
    -- dry-run must stay offline: never download just to print the command
    local plan = build_plan(host, opts, rest, not opts["dry-run"])
    if opts.java_mismatch and not opts["ignore-java-check"] then
        error(opts.java_mismatch .. "（如确认要覆盖，加 --ignore-java-check）")
    end

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
    local logpath = util.join(workdir_of(opts), "logs", "kaminec-lua.log")
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
        if opts["device-code"] or not util.IS_WINDOWS then
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
    local app, err = graph.setup(http, { name = opts.name or "Kaminec-Lua" })
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

local function cmd_profile(opts, rest)
    local sub = rest[1]
    local root = workdir_of(opts)
    local store = profile.load(root)

    if sub == "list" or sub == nil then
        print("profiles in " .. profile.path(root))
        local ids = {}
        for id in pairs(store.profiles) do ids[#ids + 1] = id end
        table.sort(ids)
        if #ids == 0 then print("  (none)") end
        for _, id in ipairs(ids) do
            local p = store.profiles[id]
            print(string.format("  %-24s %-32s %s", id, tostring(p.version),
                p.external and "external" or "managed"))
        end
        return
    end

    if sub == "create" then
        local function settings_from_opts()
            local s = {}
            if opts.java then s.java = opts.java end
            if opts.memory then s.memory = opts.memory end
            if opts.account then s.account = opts.account end
            if opts.username then s.username = opts.username end
            if opts["java-auto"] then s.java_auto = true end
            return s
        end
        if opts["from-existing"] then
            local info, derr = profile.detect_existing(opts["from-existing"], rest[2] or opts.version)
            if not info then error(derr) end
            local id, p = profile.create(store, {
                root = info.root,
                version = info.version,
                name = opts.name or ("Existing " .. info.version),
                id = opts.id,
                game_dir = opts["game-dir"] or info.game_dir,
                natives_dir = opts["natives-dir"] or info.natives_dir,
                external = true,
                settings = settings_from_opts(),
                source = { launcher = "existing", path = opts["from-existing"] },
            })
            profile.save(root, store)
            print("attached existing profile " .. id .. " (" .. p.version .. ")")
            print("  root:     " .. p.root)
            print("  game_dir: " .. p.game_dir)
            return
        end
        local version = rest[2] or opts.version
        if not version then error("usage: profile create <version> [--name name] | profile create --from-existing <dir> [--version id]") end
        local id, p = profile.create(store, {
            root = root,
            version = version,
            name = opts.name,
            id = opts.id,
            game_dir = opts["game-dir"],
            natives_dir = opts["natives-dir"],
            external = opts.external or false,
            settings = settings_from_opts(),
        })
        profile.save(root, store)
        print("created profile " .. id .. " (" .. p.version .. ")")
        print("  game_dir: " .. p.game_dir)
        return
    end

    if sub == "import" then
        local from = opts.from or "official"
        if from ~= "official" and from ~= "curseforge" then
            error("目前只支持 --from official|curseforge；第三方启动器导入以后放到 tools/")
        end
        local result, err = profile.import_official(store, opts["source-dir"], { launcher = from })
        if not result then error(err) end
        print("source: " .. result.root)
        for _, v in ipairs(result.added) do print("  add    " .. v) end
        for _, v in ipairs(result.skipped) do print("  skip   " .. v .. "（已存在）") end
        for _, v in ipairs(result.missing) do print("  bad    " .. v) end
        if opts["dry-run"] or not opts.yes then
            print("未写入；确认后加 --yes")
            return
        end
        profile.save(root, store)
        print("saved " .. profile.path(root))
        return
    end

    if sub == "defaults" then
        local changed = false
        for _, k in ipairs({ "java", "memory", "account", "username" }) do
            if opts[k] then store.defaults[k] = opts[k]; changed = true end
        end
        if opts["java-auto"] then store.defaults.java_auto = true; changed = true end
        if changed then
            profile.save(root, store)
            print("updated defaults in " .. profile.path(root))
        end
        local d = store.defaults
        print("defaults:")
        for _, k in ipairs({ "java", "memory", "account", "username" }) do
            print(string.format("  %-10s %s", k .. ":", tostring(d[k] or "")))
        end
        return
    end

    local id = rest[2]
    local p = profile.find(store, id)
    if not p then error("profile 不存在: " .. tostring(id)) end

    if sub == "show" then
        print("id:          " .. tostring(id))
        for _, k in ipairs({ "name", "version", "root", "game_dir", "natives_dir", "external" }) do
            print(string.format("%-12s %s", k .. ":", tostring(p[k])))
        end
        local eff = profile.merge(store.defaults, p.settings)
        print("effective settings:")
        for _, k in ipairs({ "java", "memory", "account", "username" }) do
            if eff[k] then print("  " .. k .. " = " .. tostring(eff[k])) end
        end
        if eff.java_auto then print("  java_auto = true") end
        return
    end

    if sub == "edit" then
        if opts.name then p.name = opts.name end
        if opts.version then p.version = opts.version end
        if opts["game-dir"] then p.game_dir = util.abs(opts["game-dir"]) end
        if opts["natives-dir"] then p.natives_dir = util.abs(opts["natives-dir"]) end
        p.settings = p.settings or {}
        for _, k in ipairs({ "java", "memory", "account", "username" }) do
            if opts[k] then p.settings[k] = opts[k] end
        end
        if opts["java-auto"] then p.settings.java_auto = true end
        if opts["no-java-auto"] then p.settings.java_auto = nil end
        profile.save(root, store)
        print("updated profile " .. tostring(id))
        return
    end

    if sub == "delete" then
        if not opts.yes then
            print("will delete profile: " .. tostring(id) .. "（加 --yes 确认）")
            return
        end
        if not p.external and p.game_dir and p.game_dir ~= root then
            util.rmtree(p.game_dir)
        end
        store.profiles[id] = nil
        profile.save(root, store)
        print("deleted profile " .. tostring(id))
        return
    end

    error("usage: profile <list|create|show|edit|delete|import|defaults> ...")
end

local function cmd_java(opts, rest)
    local sub = rest[1] or "list"
    if sub == "list" or sub == "discover" then
        local list = java.discover()
        if #list == 0 then
            print("(no Java found; set --java or install one)")
            return
        end
        for _, j in ipairs(list) do print("  " .. java.describe(j)) end
        return
    end
    if sub == "detect" then
        local path = rest[2] or opts.path
        if not path then error("usage: java detect <path>") end
        local info = java.detect(path)
        if not info then error("无法识别 Java: " .. tostring(path)) end
        print(java.describe(info))
        return
    end
    error("usage: java <list|detect <path>>")
end

local cmds = {
    versions = cmd_versions,
    login = cmd_login,
    ["setup-app"] = cmd_setup_app,
    import = cmd_import,
    accounts = cmd_accounts,
    profile = cmd_profile,
    java = cmd_java,
    plan = cmd_plan,
    download = cmd_download,
    launch = cmd_launch,
}

local function print_global_help()
    print("Kaminec-Lua -- minimal Lua Minecraft launcher")
    print("")
    print("usage: lua src/main.lua <command> [options]")
    print("       kaminec.bat <command> [options]")
    print("")
    print("commands:")
    print("  versions    list available versions")
    print("  login       Microsoft login (browser/device code)")
    print("  setup-app   configure Azure client id")
    print("  import      import official launcher token")
    print("  accounts    list/manage stored accounts")
    print("  profile     create/list/show/edit/delete/import profiles")
    print("  java        list/detect installed Java")
    print("  plan        print launch plan JSON")
    print("  download    download files / export task list")
    print("  launch      build plan and launch the game")
    print("  help        show help: help <command>")
    print("")
    print("examples:")
    print("  kaminec.bat versions")
    print("  kaminec.bat profile list --dir .minecraft")
    print("  kaminec.bat java list")
    print("  kaminec.bat download 1.21.8 --dir .minecraft")
    print("  kaminec.bat launch 1.21.8 --dir .minecraft --name Steve")
    print("  kaminec.bat launch --profile vanilla-1.21.8 --dir .minecraft")
    print("")
    print("use -h or --help for this list; use 'help <command>' for details.")
end

local help_text = {
    versions = {
        "usage: versions [--dir <launcher-root>]",
        "Prints the latest release/snapshot and the newest releases.",
    },
    login = {
        "usage: login --dir <launcher-root> [--client-id <azure-id>]",
        "Windows uses browser + loopback; Linux uses device code.",
    },
    ["setup-app"] = {
        "usage: setup-app --dir <launcher-root> [--client-id <azure-id>]",
        "Stores the Azure application id in <launcher-root>/msa.json.",
    },
    import = {
        "usage: import --dir <launcher-root> [--yes]",
        "Imports the official launcher's short-lived token (about 24h).",
    },
    accounts = {
        "usage: accounts [list] --dir <launcher-root>",
        "Lists stored accounts (tokens stay local).",
    },
    profile = {
        "usage: profile <list|create|show|edit|delete|import|defaults> --dir <root>",
        "",
        "  profile defaults --memory 2G --java <path> --username Steve",
        "  profile create <version> --name <name> [--memory 4G] [--java-auto]",
        "  profile create --from-existing <instance-or-version-dir> [--version <id>]",
        "  profile import --from official|curseforge [--dry-run] [--yes]",
        "  profile list",
        "  profile show <id>",
        "  profile edit <id> [--java <path>] [--memory 4G] [--java-auto]",
        "  profile delete <id> --yes",
        "",
        "download/launch accept --profile <id>.",
    },
    java = {
        "usage: java <list|detect <path>>",
        "",
        "  java list       discover JAVA_HOME, PATH and common JDK dirs",
        "  java detect <path>  inspect one java(.exe) or JDK home",
        "",
        "launch selects a Java matching the version's required major; override with --java.",
    },
    plan = {
        "usage: plan [<version>] --dir <launcher-root> [--profile <id>]",
        "       [--out <file>] [--offline] [--java <path>]",
        "Prints the resolved plan as JSON; no files are downloaded.",
    },
    download = {
        "usage: download [<version>] --dir <launcher-root> [--profile <id>]",
        "       [--repair|--verify] [--offline]",
        "       [--export-aria2 <file>|--export-json <file>]",
        "Downloads missing files, or exports a task list when --export-* is used.",
    },
    launch = {
        "usage: launch [<version>] --dir <launcher-root> [--profile <id>]",
        "       [--name <offline-name>|--account <stored-account>]",
        "       [--java <path>] [--memory 4G] [--dry-run] [--offline]",
        "       [--ignore-java-check]",
        "Builds the plan, downloads missing files, then starts the game.",
    },
}

local function print_help(name)
    if not name then print_global_help(); return end
    local lines = help_text[name]
    if not lines then
        print_global_help()
        print("")
        print("unknown command: " .. tostring(name))
        return
    end
    for _, line in ipairs(lines) do print(line) end
end

local function main(argv)
    local function has_help()
        for _, a in ipairs(argv) do
            if a == "-h" or a == "--help" then return true end
        end
        return false
    end
    local function first_command()
        for _, a in ipairs(argv) do
            if a:sub(1, 1) ~= "-" then return a end
        end
    end
    if argv[1] == "help" then
        print_help(argv[2])
        return
    end
    if has_help() then
        print_help(first_command())
        return
    end
    if #argv == 0 then
        print_help()
        return
    end

    local opts, rest = parse(argv)
    local name = rest[1]
    local fn = name and cmds[name]
    if not fn then
        print_help(name)
        os.exit(1)
    end
    table.remove(rest, 1)
    if name ~= "profile" then resolve_profile(opts) end
    local ok, err = pcall(fn, opts, rest)
    if not ok then
        print("error: " .. tostring(err):gsub("^[^:]+:%d+: ", ""))
        os.exit(1)
    end
end

main(arg)
