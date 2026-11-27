-- OKLab and OKHSL conversions adapted from Pi and Björn Ottosson's MIT-licensed reference.
local LINEAR_SRGB_TO_LMS = {
    {0.4122214694707629, 0.5363325372617349, 0.0514459932675022},
    {0.2119034958178251, 0.6806995506452344, 0.1073969535369405},
    {0.0883024591900564, 0.2817188391361215, 0.6299787016738222},
}
local LMS_TO_LAB = {
    {0.210454268309314, 0.793617774702305, -0.0040720430116193},
    {1.9779985324311684, -2.42859224204858, 0.450593709617411},
    {0.0259040424655478, 0.7827717124575296, -0.8086757549230774},
}
local LAB_TO_LMS = {
    {1, 0.3963377773761749, 0.2158037573099136},
    {1, -0.1055613458156586, -0.0638541728258133},
    {1, -0.0894841775298119, -1.2914855480194092},
}
local LMS_TO_LINEAR_SRGB = {
    {4.0767416360759583, -3.3077115392580629, 0.2309699031821043},
    {-1.2684379732850315, 2.6097573492876882, -0.341319376002657},
    {-0.0041960761386756, -0.7034186179359362, 1.7076146940746117},
}
local SATURATION_FIT = {
    {
        {-1.8817031, -0.80936501},
        {1.19086277, 1.76576728, 0.59662641, 0.75515197, 0.56771245},
    },
    {
        {1.8144408, -1.19445267},
        {0.73956515, -0.45954404, 0.08285427, 0.12541073, -0.14503204},
    },
    {
        {0.13110758, 1.81333971},
        {1.35733652, -0.00915799, -1.1513021, -0.50559606, 0.00692167},
    },
}

local function dot(row, v)
    return row[1]*v[1] + row[2]*v[2] + row[3]*v[3]
end

local function multiply(matrix, v)
    return {dot(matrix[1],v), dot(matrix[2],v), dot(matrix[3],v)}
end

local function linear(channel)
    local x = channel / 255
    return if x <= 0.04045 then x / 12.92 else ((x + 0.055) / 1.055)^2.4
end

local function toChannel(x)
    return math.round(255 * math.clamp(if x > 0.0031308 then 1.055 * x^(1/2.4) - 0.055 else 12.92 * x, 0, 1))
end

local function rgbOf(v)
    return {r=toChannel(v[1]), g=toChannel(v[2]), b=toChannel(v[3])}
end

local function toLab(rgb)
    local lms = multiply(LINEAR_SRGB_TO_LMS, {linear(rgb.r), linear(rgb.g), linear(rgb.b)})
    return multiply(LMS_TO_LAB, {lms[1]^(1/3), lms[2]^(1/3), lms[3]^(1/3)})
end

local function toLinear(l, a, b)
    local lms = multiply(LAB_TO_LMS, {l,a,b})
    return multiply(LMS_TO_LINEAR_SRGB, {lms[1]^3, lms[2]^3, lms[3]^3})
end

local function slopes(a, b)
    return multiply(LAB_TO_LMS, {0,a,b})
end

local function derivatives(l, chroma, k)
    local f, first, second = {}, {}, {}
    for i = 1,3 do
        local x = l + chroma*k[i]
        f[i], first[i], second[i] = x^3, 3*k[i]*x^2, 6*k[i]^2*x
    end
    return f, first, second
end

local function chromaStops(l, a, b)
    local channel = 3
    for i=1,2 do
        local h = SATURATION_FIT[i][1]
        if h[1]*a + h[2]*b > 1 then
            channel = i
            break
        end
    end
    local k = slopes(a,b)
    local v = SATURATION_FIT[channel][2]
    local fit = v[1] + v[2]*a + v[3]*b + v[4]*a*a + v[5]*a*b
    local x, y, z = derivatives(1,fit,k)
    local weights = LMS_TO_LINEAR_SRGB[channel]
    local f, f1, f2 = dot(weights,x), dot(weights,y), dot(weights,z)
    local saturation = fit - f*f1 / (f1*f1 - 0.5*f*f2)
    local peakL = (1 / math.max(table.unpack(toLinear(1,saturation*a,saturation*b))))^(1/3)
    local peakC = peakL*saturation
    local edge = math.min(peakC*l/peakL, peakC*(l-1)/(peakL-1))
    local maximum = edge
    if l > peakL then
        x,y,z = derivatives(l,edge,k)
        local step = math.huge
        for _, row in ipairs(LMS_TO_LINEAR_SRGB) do
            f,f1,f2 = dot(row,x)-1, dot(row,y), dot(row,z)
            local u = f1 / (f1*f1 - 0.5*f*f2)
            if u >= 0 then step = math.min(step, -f*u) end
        end
        maximum += step
    end
    local midS = 0.11516993 + 1/(7.4477897 + 4.1590124*b + a*(-2.19557347 + 1.75198401*b + a*(-2.13704948 - 10.02301043*b + a*(-4.24894561 + 5.38770819*b + 4.69891013*a))))
    local midT = 0.11239642 + 1/(1.6132032 - 0.68124379*b + a*(0.40370612 + 0.90148123*b + a*(-0.27087943 + 0.6122399*b + a*(0.00299215 - 0.45399568*b - 0.14661872*a))))
    return math.sqrt(1/(1/(l*0.4)^2 + 1/((1-l)*0.8)^2)),
        0.9 * maximum/edge * (1/(1/(l*midS)^4 + 1/((1-l)*midT)^4))^0.25, maximum
end

local k1, k2, k3 = 0.206, 0.03, 1.206 / 1.03
local function perceptual(l)
    local x = k3*l - k1
    return (x + math.sqrt(x*x + 4*k2*k3*l))/2
end

local function okhsl(h, s, lightness)
    local l = (lightness*lightness + k1*lightness)/(k3*(lightness + k2))
    if l <= 0 or l >= 1 or s == 0 then return rgbOf(toLinear(l,0,0)) end
    local angle = math.rad(h % 360)
    local a,b = math.cos(angle),math.sin(angle)
    local c0, mid, maximum = chromaStops(l,a,b)
    local c
    if s < 0.8 then
        local t, k = 1.25*s, 0.8*c0
        c = t*k / (1 - (1 - k/mid)*t)
    else
        local t, k = 5*(s-0.8), 0.2*mid^2*1.25^2/c0
        c = mid + t*k/(1 - (1 - k/(maximum-mid))*t)
    end
    return rgbOf(toLinear(l,c*a,c*b))
end

local function sourceOf(rgb)
    local lab = toLab(rgb)
    local l,a,b = lab[1],lab[2],lab[3]
    local c = math.sqrt(a*a + b*b)
    local h, lightness = math.deg(math.atan2(b,a)) % 360, perceptual(l)
    if c < 1e-9 or lightness <= 0 or lightness >= 1 then return {h=0,s=0,l=lightness,c=c} end
    local c0, mid, maximum = chromaStops(l,a/c,b/c)
    local saturation
    if c < mid then
        local k = 0.8*c0
        saturation = 0.8*c/(k + (1 - k/mid)*c)
    else
        local k, offset = 0.2*mid^2*1.25^2/c0, c-mid
        saturation = 0.8 + 0.2*offset/(k + (1 - k/(maximum-mid))*offset)
    end
    return {h=h,s=math.clamp(saturation,0,1),l=lightness,c=c}
end

local function oklch(l,c,h)
    local a,b = math.cos(math.rad(h % 360)), math.sin(math.rad(h % 360))
    local function inGamut(v)
        return math.min(table.unpack(v)) >= -1e-7 and math.max(table.unpack(v)) <= 1+1e-7
    end
    local rgb = toLinear(l,c*a,c*b)
    if inGamut(rgb) then return rgbOf(rgb) end
    rgb = toLinear(l,0,0)
    local low,high = 0,c
    for _ = 1,20 do
        local mid = (low+high)/2
        local v = toLinear(l,mid*a,mid*b)
        if inGamut(v) then low,rgb = mid,v else high = mid end
    end
    return rgbOf(rgb)
end

local function parseColor(value)
    local hex = string.match(value, "^#(%x+)$")
    if hex and (#hex == 3 or #hex == 6) then
        if #hex == 3 then hex = string.gsub(hex, ".", function(x) return x..x end) end
        return {r=tonumber(hex:sub(1,2),16),g=tonumber(hex:sub(3,4),16),b=tonumber(hex:sub(5,6),16)}
    end
    local kind, a, b, c = string.lower(value):match("^(oklch)%(%s*(%S+)%s+(%S+)%s+(%S+)%s*%)$")
    if not kind then kind,a,b,c = string.lower(value):match("^(okhsl)%(%s*(%S+)%s+(%S+)%s+(%S+)%s*%)$") end
    assert(kind, "Invalid theme color")
    local function number(text, unit)
        local scaled = unit == "%" and text:sub(-1) == "%"
        if scaled then text=text:sub(1,-2) elseif unit == "deg" then text=text:gsub("deg$","") end
        assert(text:match("^[+%-%.%de]+$"), "Invalid color component")
        local result = tonumber(text)
        assert(result and math.abs(result) < math.huge, "Invalid color component")
        return if scaled then result/100 else result
    end
    if kind == "oklch" then
        local l, chroma, h = number(a,"%"),number(b),number(c,"deg")
        assert(l >= 0 and l <= 1 and chroma >= 0, "OKLCH component out of range")
        return oklch(l,chroma,h)
    end
    local h,s,l = number(a,"deg"),number(b,"%"),number(c,"%")
    assert(s >= 0 and s <= 1 and l >= 0 and l <= 1, "OKHSL component out of range")
    return okhsl(h,s,l)
end

local function toIndex(color)
    local steps = {0,95,135,175,215,255}
    local function nearest(value)
        local best = 1
        for i = 2,#steps do
            if math.abs(value-steps[i]) < math.abs(value-steps[best]) then best=i end
        end
        return best - 1
    end
    local r,g,b = nearest(color.r),nearest(color.g),nearest(color.b)
    if math.max(color.r,color.g,color.b) - math.min(color.r,color.g,color.b) < 10 then
        local gray = math.round(0.299*color.r + 0.587*color.g + 0.114*color.b)
        local offset = math.clamp(math.floor((gray-4)/10),0,23)
        local value = 8 + 10*offset
        local function distance(red,green,blue)
            return 0.299*(red-color.r)^2 + 0.587*(green-color.g)^2 + 0.114*(blue-color.b)^2
        end
        if distance(value,value,value) < distance(steps[r+1],steps[g+1],steps[b+1]) then return 232+offset end
    end
    return 16 + 36*r + 6*g + b
end
