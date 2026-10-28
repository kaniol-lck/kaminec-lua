-- arguments.lua: build JVM / game argument lists from version docs
--
-- Modern (1.13+) version jsons carry structured `arguments.jvm` /
-- `arguments.game` arrays. 1.12.2 and older carry a single whitespace
-- separated `minecraftArguments` string instead; it is parsed here so the
-- rest of the launcher always sees the same argument-list shape.
local rules = require("rules")

local M = {}

local function append(out, args, features)
    for _, a in ipairs(args) do
        if type(a) == "string" then
            out[#out + 1] = a
        else
            local v = a.value
            if v ~= nil and rules.allowed(a.rules, features) then
                if type(v) == "table" then
                    for _, x in ipairs(v) do out[#out + 1] = x end
                else
                    out[#out + 1] = v
                end
            end
        end
    end
end

local function collect(docs, key, features)
    local out = {}
    for _, doc in ipairs(docs) do
        local args = doc.arguments and doc.arguments[key]
        if args then
            append(out, args, features)
        end
    end
    return out
end

-- Old format: one whitespace-separated string. The first doc that has one
-- wins: a loader's string already contains the full vanilla argument list, so
-- concatenating the inherited parent string would duplicate every option.
local function collect_legacy_game(docs)
    for _, doc in ipairs(docs) do
        local s = doc.minecraftArguments
        if type(s) == "string" and s ~= "" then
            local out = {}
            for tok in s:gmatch("%S+") do out[#out + 1] = tok end
            return out
        end
    end
    return nil
end

local function substitute(s, ph)
    return (s:gsub("%$%{([%w_]+)%}", function(k)
        local v = ph[k]
        if v == nil then return "${" .. k .. "}" end
        return v
    end))
end

-- returns jvm_args, game_args, legacy
-- legacy == true when game args came from minecraftArguments (old format)
function M.build(docs, ph, features)
    local jvm, game = {}, {}
    for _, a in ipairs(collect(docs, "jvm", features)) do jvm[#jvm + 1] = substitute(a, ph) end

    local modern_game = collect(docs, "game", features)
    local legacy = false
    if #modern_game > 0 then
        for _, a in ipairs(modern_game) do game[#game + 1] = substitute(a, ph) end
    else
        local old_game = collect_legacy_game(docs)
        if old_game then
            legacy = true
            for _, a in ipairs(old_game) do game[#game + 1] = substitute(a, ph) end
        end
    end
    return jvm, game, legacy
end

return M
