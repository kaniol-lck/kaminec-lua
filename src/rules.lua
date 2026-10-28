-- rules.lua: official version-json rule evaluation
local M = {}

local OS_NAME = "windows"
local OS_ARCH = "x86_64"

local function arch_matches(arch)
    if arch == "x86" then return OS_ARCH == "x86" end
    if arch == "x86_64" or arch == "amd64" then return OS_ARCH == "x86_64" end
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
