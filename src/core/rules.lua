-- rules.lua: official version-json rule evaluation (platform-aware).
local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function uname(flag)
    local f = io.popen("uname " .. flag .. " 2>/dev/null")
    if not f then return "" end
    local s = f:read("l") or ""
    f:close()
    return (s:gsub("%s+$", ""))
end

local OS_NAME, OS_ARCH
if IS_WINDOWS then
    OS_NAME = "windows"
    local pa = (os.getenv("PROCESSOR_ARCHITECTURE") or "AMD64"):upper()
    OS_ARCH = pa:find("64") and "x86_64" or "x86"
else
    OS_NAME = (uname("-s") == "Darwin") and "osx" or "linux"
    local m = uname("-m")
    if m == "x86_64" or m == "amd64" then
        OS_ARCH = "x86_64"
    elseif m == "aarch64" or m == "arm64" then
        OS_ARCH = "arm64"
    else
        OS_ARCH = m ~= "" and m or "x86_64"
    end
end

M.OS_NAME = OS_NAME
M.OS_ARCH = OS_ARCH

local function arch_matches(arch)
    if arch == "x86" then return OS_ARCH == "x86" end
    if arch == "x86_64" or arch == "amd64" then return OS_ARCH == "x86_64" end
    if arch == "arm64" or arch == "aarch64" then return OS_ARCH == "arm64" end
    return false
end

local function os_matches(spec)
    if spec.name and spec.name ~= OS_NAME then return false end
    if spec.arch then return arch_matches(spec.arch) end
    return true
end

local function features_match(want, have)
    for k, v in pairs(want) do
        if (have[k] or false) ~= v then return false end
    end
    return true
end

-- rules: array or nil; features: table (missing key == false)
-- official semantics: no rules -> allow; else last matching rule wins
function M.allowed(rules, features)
    features = features or {}
    if not rules or #rules == 0 then return true end
    local allow = false
    for _, rule in ipairs(rules) do
        local match = true
        if rule.os then match = os_matches(rule.os) end
        if match and rule.features then match = features_match(rule.features, features) end
        if match then allow = (rule.action == "allow") end
    end
    return allow
end

return M
