-- sha256.lua: pure Lua SHA-256 (Lua 5.4 bitwise operators).
local M = {}

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local U32 = 0xFFFFFFFF

local function rotr(x, n)
    x = x & U32
    return ((x >> n) | (x << (32 - n))) & U32
end

local function hex(n)
    return string.format("%08x", n & U32)
end

function M.hex(msg)
    msg = tostring(msg)
    local h = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
    local bitlen = #msg * 8
    local data = msg .. "\128"
    while (#data % 64) ~= 56 do data = data .. "\0" end
    data = data .. string.pack(">I8", bitlen)

    for block = 1, #data, 64 do
        local w = {}
        for j = 0, 15 do
            w[j] = string.unpack(">I4", data, block + j * 4)
        end
        for j = 16, 63 do
            local a15, a2 = w[j - 15], w[j - 2]
            local s0 = rotr(a15, 7) ~ rotr(a15, 18) ~ (a15 >> 3)
            local s1 = rotr(a2, 17) ~ rotr(a2, 19) ~ (a2 >> 10)
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) & U32
        end

        local a, b, c, d, e, f, g, hh =
            h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for j = 0, 63 do
            local S1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
            local ch = (e & f) ~ ((~e) & g)
            local t1 = (hh + S1 + ch + K[j + 1] + w[j]) & U32
            local S0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & U32
            hh = g
            g = f
            f = e
            e = (d + t1) & U32
            d = c
            c = b
            b = a
            a = (t1 + t2) & U32
        end
        h[1] = (h[1] + a) & U32
        h[2] = (h[2] + b) & U32
        h[3] = (h[3] + c) & U32
        h[4] = (h[4] + d) & U32
        h[5] = (h[5] + e) & U32
        h[6] = (h[6] + f) & U32
        h[7] = (h[7] + g) & U32
        h[8] = (h[8] + hh) & U32
    end
    return table.concat({ hex(h[1]), hex(h[2]), hex(h[3]), hex(h[4]),
        hex(h[5]), hex(h[6]), hex(h[7]), hex(h[8]) })
end

return M
