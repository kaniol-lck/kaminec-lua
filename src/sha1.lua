-- sha1.lua: pure Lua SHA1 (RFC 3174/1321), no third-party dependencies.
--
-- API:
--   sha1.hex(str)        -> 40 lowercase hex chars
--   sha1.file(path)      -> 40 lowercase hex chars, nil when the file is unreadable
--   sha1.new()           -> streaming state
--   sha1.update(state, s)-> state
--   sha1.finish(state)   -> hex digest
--
-- The streaming form is used for multi-megabyte jars so files never have to be
-- loaded into a single Lua string.

local M = {}

local U32 = 0xFFFFFFFF
local BLOCK = 64

local function rol(x, n)
    x = x & U32
    return ((x << n) | (x >> (32 - n))) & U32
end

local function process(st, block)
    local w = st.w
    for i = 0, 15 do
        local o = i * 4
        w[i] = (string.byte(block, o + 1) << 24)
            | (string.byte(block, o + 2) << 16)
            | (string.byte(block, o + 3) << 8)
            | string.byte(block, o + 4)
    end

    local h = st.h
    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]

    for i = 0, 79 do
        local j = i % 16
        local wi
        if i < 16 then
            wi = w[j]
        else
            wi = rol(w[(j + 13) % 16] ~ w[(j + 8) % 16] ~ w[(j + 2) % 16] ~ w[j], 1)
            w[j] = wi
        end

        local f, k
        if i < 20 then
            f = (b & c) | ((~b) & d)
            k = 0x5A827999
        elseif i < 40 then
            f = b ~ c ~ d
            k = 0x6ED9EBA1
        elseif i < 60 then
            f = (b & c) | (b & d) | (c & d)
            k = 0x8F1BBCDC
        else
            f = b ~ c ~ d
            k = 0xCA62C1D6
        end

        local t = (rol(a, 5) + f + e + k + wi) & U32
        e = d
        d = c
        c = rol(b, 30)
        b = a
        a = t
    end

    h[1] = (h[1] + a) & U32
    h[2] = (h[2] + b) & U32
    h[3] = (h[3] + c) & U32
    h[4] = (h[4] + d) & U32
    h[5] = (h[5] + e) & U32
end

function M.new()
    return {
        h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 },
        w = {},
        buf = "",
        total = 0,
    }
end

function M.update(st, data)
    if not data or data == "" then return st end
    st.total = st.total + #data
    local buf = st.buf .. data
    local blocks = #buf // BLOCK
    for i = 0, blocks - 1 do
        process(st, buf:sub(i * BLOCK + 1, i * BLOCK + BLOCK))
    end
    st.buf = buf:sub(blocks * BLOCK + 1)
    return st
end

function M.finish(st)
    local bits = st.total * 8
    local pad = (55 - #st.buf) % BLOCK
    local tail = st.buf .. "\128" .. string.rep("\0", pad)
    local bytes = {}
    for i = 7, 0, -1 do
        bytes[#bytes + 1] = string.char((bits >> (i * 8)) & 0xFF)
    end
    tail = tail .. table.concat(bytes)
    for i = 0, #tail // BLOCK - 1 do
        process(st, tail:sub(i * BLOCK + 1, i * BLOCK + BLOCK))
    end
    local out = {}
    for i = 1, 5 do
        out[i] = string.format("%08x", st.h[i])
    end
    return table.concat(out)
end

function M.hex(data)
    return M.finish(M.update(M.new(), data or ""))
end

function M.file(path, chunk)
    local f = io.open(path, "rb")
    if not f then return nil end
    local st = M.new()
    chunk = chunk or 262144
    while true do
        local data = f:read(chunk)
        if not data or #data == 0 then break end
        M.update(st, data)
    end
    f:close()
    return M.finish(st)
end

return M
