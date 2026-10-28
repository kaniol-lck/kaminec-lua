-- http.lua: HTTPS downloads via the system curl (same idea as KL_Launcher's luacurl)
--
-- Single-file downloads are staged in <path>.part:
--   * an existing .part is continued with `curl -C -` (resume is on by default)
--   * curl exit code 33 (server/proxy refuses byte ranges) drops the .part and
--     starts over, so a proxy that ignores Range never appends garbage
--   * when opts.sha1 is given the staged file is hashed with sha1.lua and only
--     renamed into place on a match; one mismatch triggers one clean refetch
-- Public signatures are unchanged: M.curl(), M.proxy(),
-- M.download(url, path, opts), M.ensure(url, path, expected_size, opts).
local util = require("util")
local sha1 = require("sha1")
local json = require("json")

local M = {}

-- curl's exit code when the server does not support or accept range requests
local CURL_RANGE_ERROR = 33

local function env(name)
    local v = os.getenv(name)
    if v and v ~= "" then return v end
    return nil
end

-- proxy: KAMINEC_PROXY > HTTPS_PROXY > HTTP_PROXY
local function proxy_arg()
    local p = env("KAMINEC_PROXY") or env("HTTPS_PROXY") or env("HTTP_PROXY")
    if p then return { "-x", util.quote(p) } end
    return {}
end

local curl = env("KAMINEC_CURL") or "curl.exe"

function M.curl() return curl end

function M.proxy()
    return env("KAMINEC_PROXY") or env("HTTPS_PROXY") or env("HTTP_PROXY")
end

-- os.execute: success -> true; failure -> nil, "exit", code (Windows keeps the
-- raw exit status, no 256 multiplier).
local function run(cmd)
    local ok, _, code = os.execute(cmd)
    if ok == true or ok == 0 then return true, 0 end
    return false, tonumber(code) or -1
end

local function build_cmd(url, part, timeout, resuming)
    -- NOTE: never quote the executable: cmd.exe strips outer quotes when
    -- the command line starts with one (cmd /c "..." rule).
    local cmd = { curl, "-sS", "-L", "--fail", "-m", tostring(timeout) }
    for _, a in ipairs(proxy_arg()) do cmd[#cmd + 1] = a end
    if resuming then
        cmd[#cmd + 1] = "-C"
        cmd[#cmd + 1] = "-"
    end
    cmd[#cmd + 1] = "-o"
    cmd[#cmd + 1] = util.quote(part)
    cmd[#cmd + 1] = util.quote(url)
    return table.concat(cmd, " ")
end

local function verify(part, expected)
    if expected == nil or expected == "" then return true end
    local actual = sha1.file(part)
    if actual ~= nil and actual:lower() == tostring(expected):lower() then
        return true
    end
    return false, actual
end

-- os.rename does not replace an existing file on Windows: remove the stale
-- target first (repair mode relies on this). The retry covers a transient
-- sharing violation from an indexer/antivirus.
local function move_into_place(part, path)
    os.remove(path)
    local ok, err = os.rename(part, path)
    if ok then return true end
    os.remove(path)
    ok, err = os.rename(part, path)
    if ok then return true end
    return false, err
end

function M.download(url, path, opts)
    opts = opts or {}
    util.mkdir(util.dirname(path))
    local attempts = opts.attempts or 3
    local timeout = opts.timeout or 300
    local expected = opts.sha1
    if expected == "" then expected = nil end
    local resume = opts.resume ~= false
    local part = path .. ".part"
    local mismatch_retried = false
    local skip_resume = false
    local attempt = 1

    while attempt <= attempts do
        local resuming = resume and not skip_resume and util.size(part) > 0
        local ok, code = run(build_cmd(url, part, timeout, resuming))

        if not ok and resuming and code == CURL_RANGE_ERROR then
            -- the server ignored/refused the Range request: drop the partial
            -- data and fetch the whole file instead of appending garbage
            print(string.format("  resume refused: %s", url))
            os.remove(part)
            skip_resume = true -- never loop on the same .part if the delete failed
        elseif not ok then
            if util.size(part) <= 0 then os.remove(part) end
            if attempt < attempts then
                print(string.format("  retry %d/%d: %s", attempt, attempts, url))
                os.execute("ping -n 2 127.0.0.1 >nul")
            end
            attempt = attempt + 1
        else
            local verified, actual = verify(part, expected)
            if verified then
                local moved, err = move_into_place(part, path)
                if not moved then
                    error("download failed, cannot move into place: " .. path
                        .. " (" .. tostring(err) .. ")")
                end
                return path
            end
            os.remove(part)
            if mismatch_retried or attempt >= attempts then
                error(string.format("sha1 mismatch: %s (expected %s, got %s)",
                    path, tostring(expected), tostring(actual)))
            end
            mismatch_retried = true
            print(string.format("  sha1 mismatch, refetching: %s", url))
            attempt = attempt + 1
        end
    end
    error("download failed: " .. url)
end

-- download only when file is missing or size does not match (size can be nil)
function M.ensure(url, path, expected_size, opts)
    if util.exists(path) then
        local have = util.size(path)
        if (not expected_size) or expected_size == 0 or have == expected_size then
            return false -- already there
        end
    end
    M.download(url, path, opts)
    return true
end

-- ---------------------------------------------------------------------------
-- JSON / form helpers used by the Microsoft login flow (CLI path).
-- The response body is staged in a temp file; the HTTP status comes from
-- curl's -w output. Plugin hosts can inject their own httpc with the same
-- post_json/post_form/get_json interface.
-- ---------------------------------------------------------------------------
function M.request(url, opts)
    opts = opts or {}
    local resp = os.tmpname()
    local bodyfile = nil
    local cmd = { curl, "-sS", "-L", "--max-time", tostring(opts.timeout or 60) }
    for _, a in ipairs(proxy_arg()) do cmd[#cmd + 1] = a end
    if opts.method then
        cmd[#cmd + 1] = "-X"
        cmd[#cmd + 1] = opts.method
    end
    for k, v in pairs(opts.headers or {}) do
        cmd[#cmd + 1] = "-H"
        cmd[#cmd + 1] = util.quote(k .. ": " .. v)
    end
    if opts.body and opts.body ~= "" then
        bodyfile = os.tmpname()
        util.write(bodyfile, opts.body)
        cmd[#cmd + 1] = "-d"
        cmd[#cmd + 1] = util.quote("@" .. bodyfile)
    end
    cmd[#cmd + 1] = "-o"
    cmd[#cmd + 1] = util.quote(resp)
    cmd[#cmd + 1] = "-w"
    cmd[#cmd + 1] = util.quote("%{http_code}")
    cmd[#cmd + 1] = util.quote(url)

    local f = io.popen(table.concat(cmd, " "), "r")
    local status_text = f and f:read("a") or "0"
    if f then f:close() end
    local status = tonumber((status_text or ""):match("(%d+)") or "0") or 0
    local body = util.exists(resp) and util.read(resp) or ""
    os.remove(resp)
    if bodyfile then os.remove(bodyfile) end
    return status, body
end

local function form_encode(params)
    local out = {}
    for k, v in pairs(params) do
        local s = tostring(v)
        s = s:gsub("([^%w%-%._~ ])", function(c)
            return string.format("%%%02X", c:byte())
        end)
        s = s:gsub(" ", "+")
        out[#out + 1] = k .. "=" .. s
    end
    return table.concat(out, "&")
end

function M.post_json(url, tbl, opts)
    opts = opts or {}
    local headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    return M.request(url, {
        method = "POST",
        headers = headers,
        body = json.encode(tbl),
        timeout = opts.timeout,
    })
end

function M.post_form(url, params, opts)
    opts = opts or {}
    local headers = { ["Content-Type"] = "application/x-www-form-urlencoded", ["Accept"] = "application/json" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    return M.request(url, {
        method = "POST",
        headers = headers,
        body = form_encode(params),
        timeout = opts.timeout,
    })
end

function M.get_json(url, opts)
    opts = opts or {}
    local headers = { ["Accept"] = "application/json" }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    return M.request(url, { method = "GET", headers = headers, timeout = opts.timeout })
end

return M
