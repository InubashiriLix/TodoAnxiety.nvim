-- Minimal SHA-256 for Neovim 0.10 Blob values.
--
-- vim.fn.sha256() rejects a Blob ("Using a Blob as a String") even though the
-- Lua value looks like a string. Attachments must keep the real content hash,
-- especially for cloud verification, so hash the byte list directly instead of
-- hashing a lossy conversion.
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, ror = bit.rshift, bit.ror

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

local function u32(value)
    return value % 4294967296
end

local function hex(value)
    return string.format("%08x", u32(value))
end

local M = {}

---Hash a list of byte values (0..255).
---@param bytes integer[]
---@return string 64 lowercase hexadecimal characters
function M.bytes(bytes)
    local length = #bytes
    local padded = length + 1
    local remainder = padded % 64
    local zeros = remainder <= 56 and 56 - remainder or 120 - remainder
    local total = padded + zeros + 8
    local high = math.floor(length * 8 / 4294967296)
    local low = (length * 8) % 4294967296

    local function byte(index)
        if index <= length then
            return bytes[index]
        end
        if index == length + 1 then
            return 0x80
        end
        local tail = total - index
        if tail >= 0 and tail < 8 then
            local value
            if tail >= 4 then
                value = math.floor(high / 2 ^ ((tail - 4) * 8)) % 256
            else
                value = math.floor(low / 2 ^ (tail * 8)) % 256
            end
            return value
        end
        return 0
    end

    local h0, h1, h2 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372
    local h3, h4, h5 = 0xa54ff53a, 0x510e527f, 0x9b05688c
    local h6, h7 = 0x1f83d9ab, 0x5be0cd19
    local w = {}

    for offset = 0, total - 1, 64 do
        for i = 0, 15 do
            local j = offset + i * 4 + 1
            local value = byte(j) * 0x1000000 + byte(j + 1) * 0x10000 + byte(j + 2) * 0x100 + byte(j + 3)
            w[i] = value
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(bxor(ror(x, 7), ror(x, 18)), rshift(x, 3))
            local s1 = bxor(bxor(ror(y, 17), ror(y, 19)), rshift(y, 10))
            w[i] = u32(w[i - 16] + s0 + w[i - 7] + s1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for i = 0, 63 do
            local s1 = bxor(bxor(ror(e, 6), ror(e, 11)), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = u32(h + s1 + ch + K[i + 1] + w[i])
            local s0 = bxor(bxor(ror(a, 2), ror(a, 13)), ror(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = u32(s0 + maj)
            h, g, f, e = g, f, e, u32(d + t1)
            d, c, b, a = c, b, a, u32(t1 + t2)
        end
        h0, h1, h2, h3 = u32(h0 + a), u32(h1 + b), u32(h2 + c), u32(h3 + d)
        h4, h5, h6, h7 = u32(h4 + e), u32(h5 + f), u32(h6 + g), u32(h7 + h)
    end

    return hex(h0) .. hex(h1) .. hex(h2) .. hex(h3) .. hex(h4) .. hex(h5) .. hex(h6) .. hex(h7)
end

return M
