-- java.lua: discover installed Java runtimes and match them to a version json's
-- javaVersion.majorVersion. No Java download here; that stays optional.
local util = require("util")

local M = {}

local function exe_name()
    return util.IS_WINDOWS and "java.exe" or "java"
end

M.EXE = exe_name()

local function java_in_home(home)
    return util.join(home, "bin", M.EXE)
end

local function major_of(version)
    version = tostring(version or "")
    local v = version:match("(%d+%.%d+%.%d+_[%d]+)") or version:match("(%d+%.%d+%.[%d]+)")
        or version:match("(%d+%.%d+)") or version:match("(%d+)")
    if not v then return nil end
    if v:match("^1%.(%d+)") then
        return tonumber(v:match("^1%.(%d+)"))
    end
    return tonumber(v:match("^(%d+)"))
end

function M.parse_release(text)
    local version = text:match('JAVA_VERSION%s*=%s*"([^"]+)"')
    local vendor = text:match('IMPLEMENTOR%s*=%s*"([^"]*)"') or text:match('JAVA_VENDOR%s*=%s*"([^"]*)"')
    local arch = text:match('OS_ARCH%s*=%s*"([^"]*)"')
    return { version = version, major = major_of(version), vendor = vendor, arch = arch }
end

local function version_from_output(output)
    local version = output:match('version "([^"]+)"') or output:match("version%s+([%w%._]+)")
    return version or output:match("(%d+%.%d+%.%d+[_%w]*)")
end

-- path may point at java(.exe) or at the Java home.
function M.detect(path)
    path = tostring(path or "")
    local home
    if path:match("[/\\]bin[/\\][^/\\]+$") or path:match("[/\\]bin$") then
        home = util.dirname(util.dirname(path))
    elseif util.isdir(util.join(path, "bin")) then
        home = path
    else
        home = util.dirname(util.dirname(path))
    end
    local exe = java_in_home(home)
    if not util.exists(exe) then
        if util.exists(path) then
            exe = path
            home = util.dirname(util.dirname(path))
        else
            return nil
        end
    end

    local release = util.join(home, "release")
    local info = { path = exe, home = home }
    if util.exists(release) then
        local parsed = M.parse_release(util.read(release))
        info.version, info.major, info.vendor, info.arch =
            parsed.version, parsed.major, parsed.vendor, parsed.arch
    end
    if not info.major then
        local f = io.popen(util.quote(exe) .. " -version 2>&1")
        local out = f and f:read("a") or ""
        if f then f:close() end
        local version = version_from_output(out)
        info.version = version
        info.major = major_of(version)
    end
    if not info.major then return nil end
    return info
end

local function list_dirs(path)
    local cmd
    if util.IS_WINDOWS then
        cmd = 'dir /b /ad "' .. path:gsub("/", "\\") .. '" 2>nul'
    else
        cmd = 'ls -1 "' .. path .. '" 2>/dev/null'
    end
    local f = io.popen(cmd)
    local out = {}
    if f then
        for raw in f:lines() do
            local line = raw:gsub("%s+$", "")
            if line ~= "" then out[#out + 1] = line end
        end
        f:close()
    end
    return out
end

local function default_roots()
    local roots = {}
    local function add(p) if p and p ~= "" then roots[#roots + 1] = p end end
    add(os.getenv("JAVA_HOME"))
    if util.IS_WINDOWS then
        local pf = os.getenv("ProgramFiles") or "C:\\Program Files"
        local pf86 = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
        local localapp = os.getenv("LOCALAPPDATA") or ""
        local userprofile = os.getenv("USERPROFILE") or ""
        add(util.join(pf, "Java"))
        add(util.join(pf, "Eclipse Adoptium"))
        add(util.join(pf, "Microsoft"))
        add(util.join(pf, "Zulu"))
        add(util.join(pf, "Amazon Corretto"))
        add(util.join(pf86, "Java"))
        if localapp ~= "" then add(util.join(localapp, "Programs", "Eclipse Adoptium")) end
        if userprofile ~= "" then add(util.join(userprofile, ".jdks")) end
    else
        add("/usr/lib/jvm")
        add("/Library/Java/JavaVirtualMachines")
        local home = os.getenv("HOME") or ""
        if home ~= "" then add(util.join(home, ".sdkman", "candidates", "java")) end
    end
    return roots
end

local function path_java()
    local cmd = util.IS_WINDOWS and "where java 2>nul" or "command -v java 2>/dev/null"
    local f = io.popen(cmd)
    local line = f and f:read("l") or nil
    if f then f:close() end
    line = line and line:gsub("%s+$", "") or ""
    if line ~= "" then return line end
end

-- Returns list of {path, home, major, version, vendor, arch}, newest first.
function M.discover(opts)
    opts = opts or {}
    local candidates = {}
    local seen = {}
    local function consider(path)
        if not path or path == "" then return end
        local info = M.detect(path)
        if info then
            local key = info.path:lower()
            if not seen[key] then
                seen[key] = true
                candidates[#candidates + 1] = info
            end
        end
    end

    if opts.include_env ~= false then consider(path_java()) end
    local roots = opts.roots or default_roots()
    for _, root in ipairs(roots) do
        consider(root)
        if util.isdir(root) then
            for _, name in ipairs(list_dirs(root)) do
                consider(util.join(root, name))
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.major ~= b.major then return (a.major or 0) > (b.major or 0) end
        return tostring(a.version or "") > tostring(b.version or "")
    end)
    return candidates
end

function M.select(major, opts)
    if not major then return nil end
    major = tonumber(major)
    local all = M.discover(opts)
    local higher
    for _, j in ipairs(all) do
        if j.major == major then return j end
        if j.major and j.major > major then
            if not higher or j.major < higher.major then higher = j end
        end
    end
    -- exact match preferred; otherwise the closest newer major is usually
    -- usable (e.g. Java 23 for a version that asks for 21).
    return higher
end

function M.describe(j)
    if not j then return "java not found" end
    return string.format("%s (Java %s, %s%s)", j.path, tostring(j.version or "?"),
        tostring(j.vendor or "unknown"), j.arch and (", " .. j.arch) or "")
end

-- returns true, actual info; false, message
function M.validate(path, required_major)
    if not required_major then return true, nil end
    local info = M.detect(path)
    if not info then return false, "无法识别 Java: " .. tostring(path) end
    if tonumber(info.major) < tonumber(required_major) then
        return false, string.format("Java 版本过低: 需要至少 Java %s，当前 %s (%s)",
            tostring(required_major), tostring(info.version), info.path)
    end
    return true, info
end

return M
