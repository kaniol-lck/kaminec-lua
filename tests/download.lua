-- tests/download.lua: offline tests for sha1 / download policy / apply stats
-- run from the project root: lua tests/download.lua
package.path = package.path .. ";./src/?.lua"

local util = require("util")
local sha1 = require("sha1")
local download = require("download")
local http = require("http")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function has_substring(list, needle)
    for _, v in ipairs(list) do
        if tostring(v):find(needle, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
print("sha1: RFC 3174 test vectors")
check("empty string", sha1.hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709", sha1.hex(""))
check("\"abc\"", sha1.hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d", sha1.hex("abc"))
check("56-byte vector",
    sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        == "84983e441c3bd26ebaae4aa1f95129e5e54670f1",
    sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
check("1,000,000 x 'a'", sha1.hex(string.rep("a", 1000000))
    == "34aa973cd4c4daa4f61eeb2bdbad27316534016f", sha1.hex(string.rep("a", 1000000)))
check("lowercase hex", sha1.hex("abc") == sha1.hex("abc"):lower())

print("sha1: streaming and files")
local st = sha1.new()
sha1.update(st, "a")
sha1.update(st, "b")
sha1.update(st, "")
sha1.update(st, "c")
check("incremental update", sha1.finish(st) == sha1.hex("abc"))

local tmp = util.abs("tests/tmp")
util.mkdir(tmp)
local fixture = util.join(tmp, "sha1-fixture.bin")
util.write(fixture, "abc")
check("sha1.file reads bytes", sha1.file(fixture) == sha1.hex("abc"), tostring(sha1.file(fixture)))
os.remove(fixture)
check("sha1.file missing -> nil", sha1.file(fixture) == nil)

-- ---------------------------------------------------------------------------
print("download.decide: policy branches")
local abc = sha1.hex("abc")
local abd = sha1.hex("abd")
check("missing -> download", download.decide(false, nil, abc, false) == "download")
check("missing + repair -> download", download.decide(false, nil, abc, true) == "download")
check("match -> skip", download.decide(true, abc, abc, false) == "skip")
check("match + repair -> skip", download.decide(true, abc, abc, true) == "skip")
check("mismatch -> mismatch", download.decide(true, abd, abc, false) == "mismatch")
check("mismatch + repair -> repair", download.decide(true, abd, abc, true) == "repair")
check("unreadable existing -> mismatch", download.decide(true, nil, abc, false) == "mismatch")
check("unreadable + repair -> repair", download.decide(true, nil, abc, true) == "repair")
check("no expected hash -> skip", download.decide(true, nil, nil, false) == "skip")
check("empty expected hash -> skip", download.decide(true, nil, "", true) == "skip")
check("uppercase hashes compare equal", download.decide(true, abc:upper(), abc, false) == "skip")

-- ---------------------------------------------------------------------------
-- fake host: no network, no disk; memory table records fetch calls
local function fake_host(files)
    local host = { files = files or {}, calls = {}, fail = {}, false_fetch = {} }
    function host.exists(path) return host.files[path] ~= nil end
    function host.sha1(path) return host.files[path] end
    function host.size(path) return -1 end
    function host.read(path) return "" end
    function host.write(path, data) host.files[path] = sha1.hex(data) end
    function host.mkdir(path) end
    function host.log(msg) end
    function host.fetch(url, path, opts)
        host.calls[#host.calls + 1] = { url = url, path = path, opts = opts }
        if host.fail[path] then error("simulated network failure: " .. path) end
        if host.false_fetch[path] then return false end
        host.files[path] = opts and opts.sha1 or nil
        return path
    end
    return host
end

local function entry(path, digest, name)
    return {
        kind = "library",
        name = name or "lib",
        url = "https://example.invalid/" .. (name or "lib") .. ".jar",
        path = path,
        size = 42,
        sha1 = digest,
    }
end

local ok_path, bad_path, miss_path = "/fake/ok.jar", "/fake/bad.jar", "/fake/missing.jar"
local good, bad = sha1.hex("good"), sha1.hex("bad")
local plan = {
    downloads = {
        entry(ok_path, good, "ok"),
        entry(bad_path, good, "bad"),
        entry(miss_path, good, "missing"),
    },
}
local function base_files()
    return { [ok_path] = good, [bad_path] = bad }
end

print("download.apply: default (no repair)")
local host = fake_host(base_files())
local stats = download.apply(host, plan)
check("total", stats.total == 3, tostring(stats.total))
check("skipped == 1", stats.skipped == 1, tostring(stats.skipped))
check("mismatched == 1", stats.mismatched == 1, tostring(stats.mismatched))
check("downloaded == 1", stats.downloaded == 1, tostring(stats.downloaded))
check("failed == 0", stats.failed == 0, tostring(stats.failed))
check("fetch called once (missing only)", #host.calls == 1, tostring(#host.calls))
check("fetch path is the missing file", host.calls[1] and host.calls[1].path == miss_path)
check("fetch got resume=true", host.calls[1] and host.calls[1].opts.resume == true)
check("fetch got expected sha1", host.calls[1] and host.calls[1].opts.sha1 == good)
check("fetch got size", host.calls[1] and host.calls[1].opts.size == 42)
check("mismatch warning recorded", has_substring(stats.warnings, "sha1 mismatch"),
    table.concat(stats.warnings, " | "))
check("mismatch file kept on disk", host.files[bad_path] == bad)

print("download.apply: repair replaces mismatched files")
local repair_host = fake_host(base_files())
local repair_stats = download.apply(repair_host, plan, { repair = true })
check("skipped == 1", repair_stats.skipped == 1, tostring(repair_stats.skipped))
check("mismatched == 0", repair_stats.mismatched == 0, tostring(repair_stats.mismatched))
check("downloaded == 2 (repair + missing)", repair_stats.downloaded == 2, tostring(repair_stats.downloaded))
check("failed == 0", repair_stats.failed == 0, tostring(repair_stats.failed))
check("fetch called twice", #repair_host.calls == 2, tostring(#repair_host.calls))
check("first fetch repairs the bad file", repair_host.calls[1] and repair_host.calls[1].path == bad_path)
check("second fetch is the missing file", repair_host.calls[2] and repair_host.calls[2].path == miss_path)
check("repair download carries sha1", repair_host.calls[1] and repair_host.calls[1].opts.sha1 == good)
check("repaired file hash updated", repair_host.files[bad_path] == good)

print("download.apply: failures are recorded, not raised")
local fail_host = fake_host({})
fail_host.fail[miss_path] = true
local fail_stats = download.apply(fail_host, { downloads = { entry(miss_path, good) } })
check("failed == 1", fail_stats.failed == 1, tostring(fail_stats.failed))
check("downloaded == 0", fail_stats.downloaded == 0, tostring(fail_stats.downloaded))
check("failure warning recorded", has_substring(fail_stats.warnings, "download failed"),
    table.concat(fail_stats.warnings, " | "))

local false_host = fake_host({})
false_host.false_fetch[miss_path] = true
local false_stats = download.apply(false_host, { downloads = { entry(miss_path, good) } })
check("fetch returning false counts as failed", false_stats.failed == 1, tostring(false_stats.failed))

print("download.apply: edges")
local empty_host = fake_host({})
local empty_stats = download.apply(empty_host, { downloads = {} })
check("empty plan -> all zero", empty_stats.total == 0 and empty_stats.downloaded == 0
    and empty_stats.skipped == 0 and empty_stats.mismatched == 0 and empty_stats.failed == 0)
check("nil plan tolerated", download.apply(fake_host({}), nil).total == 0)
local nohash_host = fake_host({})
download.apply(nohash_host, { downloads = { entry("/fake/nohash.jar", nil) } })
check("entry without sha1 still downloads", #nohash_host.calls == 1)
check("entry without sha1 passes nil sha1", nohash_host.calls[1] and nohash_host.calls[1].opts.sha1 == nil)

-- ---------------------------------------------------------------------------
print("http: existing helpers kept (no network)")
check("http.download is a function", type(http.download) == "function")
check("http.ensure is a function", type(http.ensure) == "function")
check("http.curl is non-empty", type(http.curl()) == "string" and #http.curl() > 0)
local ensure_path = util.join(tmp, "ensure.bin")
util.write(ensure_path, "abcdef")
check("http.ensure: matching size skips network",
    http.ensure("https://example.invalid/never", ensure_path, 6) == false)
os.remove(ensure_path)

print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
