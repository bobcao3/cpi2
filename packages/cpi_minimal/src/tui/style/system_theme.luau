-- Pi 1.6.1 system palette rules, adapted to Luau.
local FAMILIES = {
    neutral = { hue = 231.49, saturation = { min = 0.02, max = 0.08 }, slot = 8 },
    blue = { hue = 231.49, saturation = { min = 0.1, max = 0.68 }, slot = 4 },
    green = { hue = 158.68, saturation = { min = 0.1, max = 0.76 }, slot = 2 },
    red = { hue = 20, saturation = { min = 0.1, max = 0.92 }, slot = 1 },
    yellow = { hue = 82.36, saturation = { min = 0.5, max = 1 }, slot = 3 },
    orange = { hue = 52, saturation = { min = 0.12, max = 0.85 }, slot = 3 },
    violet = { hue = 295, saturation = { min = 0.2, max = 0.6 }, slot = 5 },
    calamine = { hue = 202.43, saturation = { min = 0.1, max = 0.74 }, slot = 6 },
    thinkingSlate = { hue = 231.49, saturation = { min = 0.08, max = 0.2 }, slot = 4 },
    thinkingBlue = { hue = 231.49, saturation = { min = 0.2, max = 0.45 }, slot = 4 },
    thinkingPeriwinkle = { hue = 263.25, saturation = { min = 0.3, max = 0.6 }, slot = 6 },
    thinkingViolet = { hue = 295, saturation = { min = 0.4, max = 0.75 }, slot = 5 },
    thinkingMagenta = { hue = 337.5, saturation = { min = 0.5, max = 0.85 }, slot = 13 },
    thinkingRed = { hue = 20, saturation = { min = 0.95, max = 1 }, slot = 1 },
}

local TOKEN_FAMILIES = {
    selectedBg = "blue",
    searchMatchBg = "orange",
    userMessageBg = "blue",
    customMessageBg = "violet",
    toolPendingBg = "neutral",
    toolSuccessBg = "green",
    toolErrorBg = "red",
    text = "neutral",
    userMessageText = "neutral",
    customMessageText = "neutral",
    toolTitle = "neutral",
    syntaxOperator = "neutral",
    syntaxPunctuation = "neutral",
    muted = "neutral",
    dim = "neutral",
    thinkingText = "neutral",
    toolOutput = "neutral",
    mdLinkUrl = "neutral",
    mdQuote = "neutral",
    mdQuoteBorder = "neutral",
    mdHr = "neutral",
    mdCodeBlockBorder = "neutral",
    toolDiffContext = "neutral",
    syntaxComment = "neutral",
    scrollbarTrack = "neutral",
    scrollbarThumb = "neutral",
    searchMatchText = "neutral",
    borderMuted = "neutral",
    accent = "violet",
    borderAccent = "violet",
    customMessageLabel = "violet",
    mdCode = "violet",
    mdListBullet = "violet",
    syntaxType = "violet",
    border = "blue",
    mdLink = "blue",
    syntaxKeyword = "blue",
    syntaxVariable = "calamine",
    success = "green",
    mdCodeBlock = "green",
    toolDiffAdded = "green",
    bashMode = "green",
    syntaxNumber = "green",
    error = "red",
    toolDiffRemoved = "red",
    warning = "yellow",
    mdHeading = "yellow",
    syntaxFunction = "yellow",
    syntaxString = "orange",
    thinkingOff = "neutral",
    thinkingMinimal = "thinkingSlate",
    thinkingLow = "thinkingBlue",
    thinkingMedium = "thinkingPeriwinkle",
    thinkingHigh = "thinkingViolet",
    thinkingXhigh = "thinkingMagenta",
    thinkingMax = "thinkingRed",
}

local LEVELS = {
    panel = {
        dark = { coefficients = {0.29131, -0.39746, 2.33185, -0.85524, -1.2076, 0.86276}, reachable = {0, 0.979} },
        light = { coefficients = {-3.74073, 27.94549, -78.44258, 112.6798, -79.60015, 22.11277}, reachable = {0.348, 1} },
    },
    track = {
        dark = { coefficients = {0.39028, -0.23015, 0.83573, 2.43829, -4.38292, 2.01582}, reachable = {0, 0.946} },
        light = { coefficients = {-5.24921, 38.37322, -107.28833, 152.10005, -106.17127, 29.18061}, reachable = {0.368, 1} },
    },
    thinking0 = {
        dark = { coefficients = {0.52988, -0.05809, -0.30924, 4.63567, -6.52933, 2.89108}, reachable = {0, 0.873} },
        light = {
            coefficients = {-28.27749, 182.85284, -469.62416, 603.15916, -384.59976, 97.35147},
            reachable = {0.51, 1},
        },
    },
    thinking1 = {
        dark = { coefficients = {0.55278, -0.03667, -0.45659, 4.95347, -6.90265, 3.0706}, reachable = {0, 0.858} },
        light = {
            coefficients = {-37.10484, 235.86282, -596.62344, 754.3633, -474.00763, 118.3551},
            reachable = {0.535, 1},
        },
    },
    thinking2 = {
        dark = { coefficients = {0.57486, -0.01765, -0.58987, 5.25227, -7.27175, 3.25532}, reachable = {0, 0.842} },
        light = {
            coefficients = {-59.89653, 377.05024, -945.07843, 1182.03145, -734.96375, 181.68658},
            reachable = {0.556, 1},
        },
    },
    thinking3 = {
        dark = { coefficients = {0.59621, -0.00062, -0.71148, 5.53588, -7.6392, 3.44606}, reachable = {0, 0.827} },
        light = {
            coefficients = {-72.07122, 445.84082, -1099.57352, 1353.88793, -829.53392, 202.26164},
            reachable = {0.58, 1},
        },
    },
    thinking4 = {
        dark = { coefficients = {0.61691, 0.01462, -0.82288, 5.80651, -8.00641, 3.64333}, reachable = {0, 0.811} },
        light = {
            coefficients = {-110.14338, 674.21488, -1645.75941, 2004.32367, -1215.15899, 293.3183},
            reachable = {0.6, 1},
        },
    },
    thinking5 = {
        dark = { coefficients = {0.63702, 0.02826, -0.92498, 6.06465, -8.37246, 3.84651}, reachable = {0, 0.795} },
        light = {
            coefficients = {-175.47701, 1063.54495, -2570.70594, 3098.80776, -1860.15527, 444.76392},
            reachable = {0.62, 1},
        },
    },
    thinking6 = {
        dark = { coefficients = {0.65658, 0.04044, -1.01835, 6.30989, -8.73529, 4.05439}, reachable = {0, 0.779} },
        light = {
            coefficients = {-183.81712, 1094.70055, -2602.68539, 3088.71276, -1826.91131, 430.75931},
            reachable = {0.643, 1},
        },
    },
    subtle = {
        dark = { coefficients = {0.56762, -0.02475, -0.5383, 5.12628, -7.10931, 3.17324}, reachable = {0, 0.848} },
        light = {
            coefficients = {-232.85459, 1376.54473, -3249.11801, 3827.91186, -2248.29472, 526.55751},
            reachable = {0.657, 1},
        },
    },
    thumb = {
        dark = { coefficients = {0.60323, 0.00278, -0.73328, 5.57157, -7.68067, 3.46933}, reachable = {0, 0.823} },
        light = {
            coefficients = {-82.89897, 511.01355, -1255.98095, 1540.76821, -940.68087, 228.58523},
            reachable = {0.586, 1},
        },
    },
    readable = {
        dark = { coefficients = {0.66937, 0.04704, -1.06871, 6.43941, -8.9332, 4.17229}, reachable = {0, 0.77} },
        light = {
            coefficients = {-1554.52576, 8733.56817, -19604.93507, 21977.72696, -12300.99599, 2749.81288},
            reachable = {0.751, 1},
        },
    },
    emphasis = {
        dark = { coefficients = {0.7303, 0.07695, -1.31626, 7.1681, -10.14436, 4.92846}, reachable = {0, 0.712} },
        light = {
            coefficients = {-4948.31942, 26870.91986, -58334.48399, 63280.17197, -34298.01053, 7430.30146},
            reachable = {0.811, 1},
        },
    },
    textOnPanel = {
        dark = { coefficients = {0.86713, 0.05232, -0.89428, 4.79014, -5.5432, 1.75023}, reachable = {0, 0.542} },
        light = {
            coefficients = {-8570.89457, 43954.60805, -90084.00702, 92220.6791, -47152.15802, 9632.27113},
            reachable = {0.867, 1},
        },
    },
    text = {
        dark = { coefficients = {0.89242, 0.02311, -0.44862, 2.34417, -0.06084, -2.63844}, reachable = {0, 0.5} },
        light = {
            coefficients = {-2004.67048, 6664.47299, -6060.70202, -1792.61209, 5133.82359, -1939.85583},
            reachable = {0.894, 1},
        },
    },
}

local panels = {"userMessageBg","toolPendingBg","toolSuccessBg","toolErrorBg","selectedBg","searchMatchBg","customMessageBg"}
local tools = {"toolPendingBg","toolSuccessBg","toolErrorBg"}
local messages = {"userMessageBg","customMessageBg"}
local foregroundTokens = {"text","userMessageText","toolTitle"}
local slots = {syntaxString=2,syntaxNumber=5,searchMatchBg=3}
local rules, order = {}, {}

local function on(...)
    local fields = {}
    for _, value in ipairs({...}) do
        if type(value) == "table" then
            for _, field in ipairs(value) do table.insert(fields,field) end
        else
            table.insert(fields,value)
        end
    end
    return fields
end

local function rule(tokens, level, ...)
    local surfaces = on(...)
    for _, token in ipairs(if type(tokens) == "string" then {tokens} else tokens) do
        if not rules[token] then rules[token]={}; table.insert(order,token) end
        table.insert(rules[token], {level=level,on=surfaces})
    end
end

rule(panels, "panel", "background")
rule("text","text","background")
rule("text","textOnPanel","selectedBg")
rule("userMessageText","textOnPanel","userMessageBg")
rule("toolTitle","textOnPanel",tools)
rule({"accent","success","error","warning"},"readable","background","selectedBg",tools)
rule("muted","readable","background","selectedBg","customMessageBg",tools)
rule("dim","subtle","background","selectedBg","customMessageBg",tools)
rule("thinkingText","readable","background")
rule("customMessageText","readable","customMessageBg",tools)
rule("customMessageLabel","readable","background","customMessageBg","selectedBg",tools)
rule("toolOutput","readable","background",tools)
rule({"mdHeading","mdLink","mdLinkUrl","mdCode","mdQuote","mdCodeBlockBorder","mdListBullet"},"readable","background",messages)
rule({"mdCodeBlock","mdQuoteBorder","mdHr"},"readable","background",messages,tools)
rule({"toolDiffAdded","toolDiffRemoved","toolDiffContext"},"readable","background",tools)
rule({"syntaxComment","syntaxKeyword","syntaxFunction","syntaxVariable","syntaxString","syntaxNumber","syntaxType","syntaxOperator","syntaxPunctuation"},"readable","background",messages,tools)
rule("searchMatchText","readable","searchMatchBg")
rule({"bashMode","border","borderAccent"},"readable","background")
rule("borderMuted","subtle","background")
rule("scrollbarTrack","track","background")
rule("scrollbarThumb","thumb","scrollbarTrack")
for index, token in ipairs({"thinkingOff","thinkingMinimal","thinkingLow","thinkingMedium","thinkingHigh","thinkingXhigh","thinkingMax"}) do
    rule(token, "thinking" .. (index-1), "background")
end

local function luminance(rgb)
    return 0.2126*linear(rgb.r) + 0.7152*linear(rgb.g) + 0.0722*linear(rgb.b)
end

local function contrast(a,b)
    local x,y = luminance(a),luminance(b)
    return (math.max(x,y)+0.05)/(math.min(x,y)+0.05)
end

local white, black = {r=255,g=255,b=255}, {r=0,g=0,b=0}

local function appearanceFor(bg,fg)
    local lightness, lightContrast, darkContrast = toLab(bg)[1], contrast(white,bg),contrast(black,bg)
    if fg then
        local foreground = toLab(fg)[1]
        if math.abs(foreground-lightness) > 0.05 then
            if foreground > lightness and lightContrast >= 4.5 then return "dark" end
            if foreground < lightness and darkContrast >= 4.5 then return "light" end
        end
    end
    return if lightContrast >= darkContrast then "dark" else "light"
end

local function bell(l)
    local edge = math.exp(-2)
    return (math.exp(-8*(l-0.5)^2)-edge)/(1-edge)
end

local function anchored(src,family,l,saturation)
    local floor = family.saturation.min/family.saturation.max
    local function curve(x) return floor + (1-floor)*bell(x) end
    local strength = math.min(1, curve(l)/curve(src.l))*saturation
    local rgb = okhsl(src.h,src.s*strength,l)
    local lab = toLab(rgb)
    local cap = src.c*strength
    return if lab[2]^2 + lab[3]^2 <= cap^2 then rgb else oklch(lab[1],cap,src.h)
end

local function generate(input)
    local bg, fg = input.background, input.foreground
    local saturation = if input.pending then 0 else 1
    local colors, dim = {}, {}
    if not bg then
        for token,family in pairs(TOKEN_FAMILIES) do
            if not table.find(panels,token) then
                if family ~= "neutral" then
                    if saturation > 0 then colors[token] = slots[token] or FAMILIES[family].slot end
                elseif not table.find(foregroundTokens,token) then
                    dim[token] = true
                end
            end
        end
        return colors,dim,input.appearance
    end
    local appearance = appearanceFor(bg,fg)
    local lighter = appearance == "dark"
    local extreme = if lighter then 1 else 0
    local extremeText = if lighter then white else black
    local backgroundL = toLab(bg)[1]
    local source = nil
    if input.palette and #input.palette == 16 then
        source = {}
        for i,rgb in ipairs(input.palette) do source[i] = sourceOf(rgb) end
    end
    local function paint(token,l)
        local lightness = math.clamp(perceptual(l),0,1)
        local family = FAMILIES[TOKEN_FAMILIES[token]]
        if source then return anchored(source[1+(slots[token] or family.slot)],family,lightness,saturation) end
        local min,max = family.saturation.min,family.saturation.max
        return okhsl(family.hue,(min+(max-min)*bell(lightness))*saturation,lightness)
    end
    local function levelTarget(level,l)
        local curve = LEVELS[level][appearance]
        if l < curve.reachable[1] or l > curve.reachable[2] then return nil end
        local target = 0
        for i,coefficient in ipairs(curve.coefficients) do target += coefficient*l^(i-1) end
        return target
    end
    local function target(level,l,relaxation)
        local reached = levelTarget(level,l)
        if reached == nil and relaxation == 0 then return nil end
        local delta = (reached or extreme)-l
        local floor = (levelTarget(if lighter then "readable" else "subtle",l) or extreme)-l
        if math.abs(delta) > math.abs(floor) then delta -= (delta-floor)*math.min(relaxation,1) end
        return l + delta*(1-math.max(0,relaxation-1))
    end
    local function limitPanel(token,l)
        local rgb = paint(token,l)
        if contrast(extremeText,rgb) >= 4.5 then return rgb end
        local low,high = backgroundL,l
        for _ = 1,20 do
            local mid = (low+high)/2
            if contrast(extremeText,paint(token,mid)) >= 4.5 then low=mid else high=mid end
        end
        return paint(token,low)
    end
    local strongest = if lighter then math.max else math.min
    local function solve(relaxation)
        local result, lightness = {}, {background=backgroundL}
        for _,token in ipairs(order) do
            local needed = 1-extreme
            for _,condition in ipairs(rules[token]) do
                for _,surface in ipairs(condition.on) do
                    local l = target(condition.level,lightness[surface],relaxation)
                    if l == nil or l < 0 or l > 1 then return nil end
                    needed = strongest(needed,l)
                end
            end
            local rgb = if table.find(panels,token) then limitPanel(token,needed) else paint(token,needed)
            result[token], lightness[token] = rgb,toLab(rgb)[1]
        end
        return result
    end
    local relaxation = 0
    colors = solve(0)
    if not colors then
        local low,high = 0,2
        colors = assert(solve(high))
        for _ = 1,20 do
            local mid = (low+high)/2
            local attempt = solve(mid)
            if attempt then high,colors=mid,attempt else low=mid end
        end
        relaxation = high
    end
    local foreground = if fg then sourceOf(fg) else nil
    for _,token in ipairs(foregroundTokens) do
        local surfaces = {}
        local needed = 1-extreme
        local useForeground = foreground ~= nil
        for _,condition in ipairs(rules[token]) do
            for _,surface in ipairs(condition.on) do
                local rgb = colors[surface] or bg
                table.insert(surfaces,rgb)
                local aim = target("emphasis",toLab(rgb)[1],relaxation)
                if aim and aim >= 0 and aim <= 1 then needed=strongest(needed,aim) else useForeground=false end
            end
        end
        local rgb = colors[token]
        if useForeground then
            local l = toLab(fg)[1]
            if strongest(l,needed) == l then
                colors[token] = nil
                continue
            end
            rgb = anchored(foreground,FAMILIES.neutral,math.clamp(perceptual(needed),0,1),saturation)
        end
        local function meets(color)
            for _,surface in ipairs(surfaces) do if contrast(color,surface) < 4.5 then return false end end
            return true
        end
        if not meets(rgb) then
            if meets(extremeText) then
                local profile = sourceOf(rgb)
                local low,high = profile.l,extreme
                for _ = 1,20 do
                    local mid = (low+high)/2
                    if meets(okhsl(profile.h,profile.s,mid)) then high=mid else low=mid end
                end
                rgb = okhsl(profile.h,profile.s,high)
            else
                rgb = extremeText
            end
        end
        colors[token] = rgb
    end
    return colors,dim,appearance
end

local fallbacks = {scrollbarTrack="muted",scrollbarThumb="text",searchMatchBg="selectedBg",searchMatchText="text",thinkingMax="thinkingXhigh"}

local function palette(input)
    local colors, dim, appearance
    local definition = input.definition
    if definition then
        colors,dim,appearance = {},{},definition.appearance or input.appearance
        local vars = definition.vars or {}
        for _,token in ipairs(input.tokens) do
            local fallback = fallbacks[token]
            local value = definition.colors[token]
            if value == nil and fallback then value=definition.colors[fallback] end
            local visited = {}
            while type(value) == "string" and value ~= "" and not value:match("^#") and not value:lower():match("^oklch%(") and not value:lower():match("^okhsl%(") do
                assert(not visited[value], "Cyclic theme variable")
                visited[value],value = true,vars[value]
            end
            if type(value) == "number" then
                assert(value >= 0 and value <= 255 and value % 1 == 0, "Invalid theme index")
                colors[token] = value
            else
                assert(type(value) == "string", "Missing theme color: "..token)
                if value ~= "" then colors[token]=parseColor(value) end
            end
        end
    else
        colors,dim,appearance = generate(input)
    end
    local result = {}
    for _,token in ipairs(input.tokens) do
        local color = colors[token]
        if type(color) == "table" then
            color = if input.truecolor then {color.r,color.g,color.b} else toIndex(color)
        end
        result[token]={color=color,faint=dim[token] == true}
    end
    return {appearance=appearance,colors=result}
end
