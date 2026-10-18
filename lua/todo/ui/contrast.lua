local M = {}
local function luminance(rgb)
    local function channel(shift)
        local value = math.floor(rgb / 2 ^ shift) % 256 / 255
        return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
    end
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
end
function M.ratio(a, b)
    local x, y = luminance(a), luminance(b)
    return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end
function M.readable(fg, bg, minimum)
    if M.ratio(fg, bg) >= minimum then
        return fg
    end
    local target = M.ratio(0xffffff, bg) > M.ratio(0, bg) and 255 or 0
    for step = 1, 32 do
        local rgb = 0
        for _, shift in ipairs({ 16, 8, 0 }) do
            local value = math.floor(fg / 2 ^ shift) % 256
            rgb = rgb + math.floor(value + (target - value) * step / 32) * 2 ^ shift
        end
        if M.ratio(rgb, bg) >= minimum or step == 32 then
            return rgb
        end
    end
end
return M
