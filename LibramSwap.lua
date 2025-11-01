-- LibramSwap.lua (Turtle WoW 1.12)
-- Rank-aware version (handles "/cast Name(Rank X)" and plain "/cast Name").
-- Swaps librams for specific spells, but ONLY when the spell is ready (no CD/GCD).
-- Preserves Judgement gating (only swap ≤35% target HP) and per-spell throttles
-- that start AFTER the first successful swap for that spell.

-- =====================
-- Locals / Aliases
-- =====================
local GetContainerNumSlots  = GetContainerNumSlots
local GetContainerItemLink  = GetContainerItemLink
local UseContainerItem      = UseContainerItem
local GetInventoryItemLink  = GetInventoryItemLink
local GetSpellName          = GetSpellName
local GetSpellCooldown      = GetSpellCooldown
local GetTime               = GetTime
local string_find           = string.find
local BOOKTYPE_SPELL        = BOOKTYPE_SPELL or "spell"

-- === Bag Index ===
local NameIndex   = {}  -- [itemName] = {bag=#, slot=#, link="|Hitem:..|h[Name]|h|r"}
local IdIndex     = {}  -- [itemID]   = {bag=#, slot=#, link=...}  (optional use later)
local reindexQueued = false

-- Safety: block swaps when vendor/bank/auction/trade/mail/quest/gossip is open
local function IsInteractionBusy()
    return (MerchantFrame and MerchantFrame:IsVisible())
        or (BankFrame and BankFrame:IsVisible())
        or (AuctionFrame and AuctionFrame:IsVisible())
        or (TradeFrame and TradeFrame:IsVisible())
        or (MailFrame and MailFrame:IsVisible())
        or (QuestFrame and QuestFrame:IsVisible())
        or (GossipFrame and GossipFrame:IsVisible())
end

local lastEquippedLibram = nil

-- Global (generic) throttle for GCD-based swaps
local lastSwapTime = 0

-- =====================
-- Config
-- =====================

-- Initialize saved variables with defaults
LibramSwapDb = LibramSwapDb or {
    enabled = false,
    spam = true,
    -- Runtime toggle for which librams to use for spells with multiple options
    -- Consecration: ("faithful" or "farraki")
    -- Holy Strike: ("eternal" or "radiance")
    consecrationMode = "faithful",
    holyStrikeMode = "eternal"
}

-- Keep original generic throttle for GCD spells
local SWAP_THROTTLE_GENERIC = 1.48

-- Per-spell throttles (begin applying AFTER the first successful swap of that spell)
local PER_SPELL_THROTTLE = {
    ["Judgement"]       = 7.8,
}

-- Consecration libram choices
local CONSECRATION_FAITHFUL = "Libram of the Faithful"
local CONSECRATION_FARRAKI  = "Libram of the Farraki Zealot"

-- Holy Strike libram choices
local HOLY_STRIKE_ETERNAL_TOWER = "Libram of the Eternal Tower"
local HOLY_STRIKE_RADIANCE  = "Libram of Radiance"

-- Map spells -> preferred libram name (bag/equipped link substring match)
local LibramMap = {
    ["Consecration"]                  = "Libram of the Faithful",
    ["Holy Shield"]                   = "Libram of the Dreamguard",
    ["Holy Light"]                    = "Libram of Radiance",
    ["Flash of Light"]                = "Libram of Light",
    ["Cleanse"]                       = "Libram of Grace",
    ["Hammer of Justice"]             = "Libram of the Justicar",
    ["Hand of Freedom"]               = "Libram of the Resolute",
    ["Crusader Strike"]               = "Libram of the Eternal Tower",
    ["Holy Strike"]                   = "Libram of the Eternal Tower",
    ["Judgement"]                     = "Libram of Final Judgement",
    ["Seal of Wisdom"]                = "Libram of Hope",
    ["Seal of Light"]                 = "Libram of Hope",
    ["Seal of Justice"]               = "Libram of Hope",
    ["Seal of Command"]               = "Libram of Hope",
    ["Seal of the Crusader"]          = "Libram of Fervor",
    ["Seal of Righteousness"]         = "Libram of Hope",
    ["Devotion Aura"]                 = "Libram of Truth",
    ["Blessing of Wisdom"]            = "Libram of Veracity",
    ["Blessing of Might"]             = "Libram of Veracity",
    ["Blessing of Kings"]             = "Libram of Veracity",
    ["Blessing of Sanctuary"]         = "Libram of Veracity",
    ["Blessing of Light"]             = "Libram of Veracity",
    ["Blessing of Salvation"]         = "Libram of Veracity",
    ["Greater Blessing of Wisdom"]    = "Libram of Veracity",
    ["Greater Blessing of Kings"]     = "Libram of Veracity",
    ["Greater Blessing of Sanctuary"] = "Libram of Veracity",
    ["Greater Blessing of Light"]     = "Libram of Veracity",
    ["Greater Blessing of Salvation"] = "Libram of Veracity",
}

local WatchedNames = {}
for _, name in pairs(LibramMap) do
    WatchedNames[name] = true
end
-- Consecration options
WatchedNames[CONSECRATION_FAITHFUL] = true
WatchedNames[CONSECRATION_FARRAKI]  = true
-- Holy  Strike options
WatchedNames[HOLY_STRIKE_ETERNAL_TOWER] = true
WatchedNames[HOLY_STRIKE_RADIANCE]  = true

-- Extract numeric itemID from an item link (1.12 safe)
local function ItemIDFromLink(link)
    if not link then return nil end
    local _, _, id = string_find(link, "item:(%d+)")
    return id and tonumber(id) or nil
end

local function BuildBagIndex()
    -- wipe current
    for k in pairs(NameIndex) do NameIndex[k] = nil end
    for k in pairs(IdIndex)   do IdIndex[k]   = nil end

    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    -- Extract plain item name safely
                    local _, _, bracketName = string_find(link, "%[(.-)%]")
                    if bracketName and WatchedNames[bracketName] then
                        NameIndex[bracketName] = { bag = bag, slot = slot, link = link }
                        local id = ItemIDFromLink(link)
                        if id then
                            IdIndex[id] = { bag = bag, slot = slot, link = link }
                        end
                    end
                end
            end
        end
    end
end

local LibramSwapFrame = CreateFrame("Frame")
LibramSwapFrame:RegisterEvent("PLAYER_LOGIN")
LibramSwapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
LibramSwapFrame:RegisterEvent("BAG_UPDATE")

LibramSwapFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        BuildBagIndex()
    elseif event == "BAG_UPDATE" then
        -- simple & safe: rebuild immediately (cost is tiny since we only watch librams)
        BuildBagIndex()
end)

-- =====================
-- Rank-aware spell parsing
-- =====================
local function SplitNameAndRank(spellSpec)
    if not spellSpec then return nil, nil end
    -- string.find returns: start, finish, CAP1, CAP2, ...
    local _, _, base, rnum = string_find(spellSpec, "^(.-)%s*%(%s*[Rr][Aa][Nn][Kk]%s*(%d+)%s*%)%s*$")
    if base then
        return (string.gsub(base, "%s+$", "")), ("Rank " .. rnum)
    end
    return (string.gsub(spellSpec, "%s+$", "")), nil
end

-- =====================
-- Spell Readiness (1.12-safe, rank-aware)
-- =====================
-- Accepts: "Name" or "Name(Rank X)". If a rank is specified, require that exact rank.
-- Returns: ready:boolean, start:number, duration:number
local function IsSpellReady(spellSpec)
    local base, reqRank = SplitNameAndRank(spellSpec)
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == base and (not reqRank or (rank and rank == reqRank)) then
            local start, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
            if not start or not duration then return false end
            if enabled == 0 then return false end
            if start == 0 or duration == 0 then return true, 0, 0 end
            local remaining = (start + duration) - GetTime()
            return remaining <= 0, start, duration
        end
    end
    return false
end

-- =====================
-- Helpers
-- =====================
-- Returns bag, slot or nil
local function HasItemInBags(itemName)
    -- 1) Try cached slot first
    local ref = NameIndex[itemName]
    if ref then
        local current = GetContainerItemLink(ref.bag, ref.slot)
        if current and string_find(current, itemName, 1, true) then
            return ref.bag, ref.slot
        end
        -- It moved; rebuild and try again
        BuildBagIndex()
        ref = NameIndex[itemName]
        if ref then
            local verify = GetContainerItemLink(ref.bag, ref.slot)
            if verify and string_find(verify, itemName, 1, true) then
                return ref.bag, ref.slot
            end
        end
        return nil
    end

    -- 2) Slow path (first time seeing this name in-session)
    --    We keep it for resiliency; BuildBagIndex will capture it for next time.
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link and string.find(link, itemName, 1, true) then
                    -- Update cache so future lookups are O(1)
                    NameIndex[itemName] = { bag = bag, slot = slot, link = link }
                    local id = ItemIDFromLink(link)
                    if id then IdIndex[id] = { bag = bag, slot = slot, link = link } end
                    return bag, slot
                end
            end
        end
    end
    return nil
end

-- Returns target HP% (number) or nil if no valid target
local function TargetHealthPct()
    if not UnitExists("target") or UnitIsDeadOrGhost("target") then return nil end
    local maxHP = UnitHealthMax("target")
    if not maxHP or maxHP == 0 then return nil end
    return (UnitHealth("target") / maxHP) * 100
end

-- Per-spell throttle state
local perSpellHasSwapped = {}   -- spellName(base) -> true after first successful swap
local perSpellLastSwap   = {}   -- spellName(base) -> last swap time (after first)

-- Core equip with throttle policy
local function EquipLibramForSpell(spellName, itemName)
    -- Already equipped?
    local equipped = GetInventoryItemLink("player", 18)
    if equipped and string_find(equipped, itemName, 1, true) then
        lastEquippedLibram = itemName
        return false
    end

    -- Block swaps if an interaction UI is open (prevents accidental selling/moving)
    if IsInteractionBusy() then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555Swap blocked (interaction window open).|r")
        return false
    end

    -- Throttle selection
    local now = GetTime()
    local perDur = PER_SPELL_THROTTLE[spellName]
    if perDur then
        -- Apply throttle ONLY after the first successful swap for this spell
        if perSpellHasSwapped[spellName] then
            local last = perSpellLastSwap[spellName] or 0
            if (now - last) < perDur then
                return false
            end
        end
    else
        -- Generic GCD-based throttle for other spells
        if (now - lastSwapTime) < SWAP_THROTTLE_GENERIC then
            return false
        end
    end

    local bag, slot = HasItemInBags(itemName)
    if bag and slot then
        if CursorHasItem and CursorHasItem() then
            return false
        end
        UseContainerItem(bag, slot)
        lastEquippedLibram = itemName
        if perDur then
            -- mark first swap and update per-spell timestamp
            if not perSpellHasSwapped[spellName] then
                perSpellHasSwapped[spellName] = true
            end
            perSpellLastSwap[spellName] = now
        else
            lastSwapTime = now
        end

        if LibramSwapDb.spam then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Equipped |cFFFFD700" .. itemName .. "|r |cFF888888(" .. spellName .. ")|r")
        end
        
        return true
    end
    return false
end

local function ResolveLibramForSpell(spellName)
    -- Special handling: Consecration libram is user-selectable
    if spellName == "Consecration" then
        local mode = (LibramSwapDb.consecrationMode == "farraki") and "farraki" or "faithful"
        if mode == "farraki" then
            if HasItemInBags(CONSECRATION_FARRAKI) then return CONSECRATION_FARRAKI end
            if HasItemInBags(CONSECRATION_FAITHFUL) then return CONSECRATION_FAITHFUL end
            return nil
        else
            if HasItemInBags(CONSECRATION_FAITHFUL) then return CONSECRATION_FAITHFUL end
            if HasItemInBags(CONSECRATION_FARRAKI) then return CONSECRATION_FARRAKI end
            return nil
        end
    end

    -- Special handling: Holy Strike libram is user-selectable
    if spellName == "Holy Strike" then
        local mode = (LibramSwapDb.holyStrikeMode == "eternal") and "eternal" or "radiance"
        if mode == "eternal" then
            if HasItemInBags(HOLY_STRIKE_ETERNAL_TOWER) then return HOLY_STRIKE_ETERNAL_TOWER end
            if HasItemInBags(HOLY_STRIKE_RADIANCE) then return HOLY_STRIKE_RADIANCE end
            return nil
        else
            if HasItemInBags(HOLY_STRIKE_RADIANCE) then return HOLY_STRIKE_RADIANCE end
            if HasItemInBags(HOLY_STRIKE_ETERNAL_TOWER) then return HOLY_STRIKE_ETERNAL_TOWER end
            return nil
        end
    end

    local libram = LibramMap[spellName]
    if not libram then return nil end

    -- Fallbacks if best pick isn't present
    if spellName == "Flash of Light" then
        if not HasItemInBags("Libram of Light") and HasItemInBags("Libram of Divinity") then
            libram = "Libram of Divinity"
        end
    end
    return libram
end

-- Trims whitespace
local function trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

-- Prints current status
local function printStatus()
    local status = LibramSwapDb.enabled and "|cFF00FF00ENABLED|r" or "|cFFFF0000DISABLED|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap] Status:|r " .. status)

    local spamStatus = LibramSwapDb.spam and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
    DEFAULT_CHAT_FRAME:AddMessage("  Swap messages: " .. spamStatus)

    -- Show Consecration setting
    local consecLibram = (LibramSwapDb.consecrationMode == "farraki") and CONSECRATION_FARRAKI or CONSECRATION_FAITHFUL
    DEFAULT_CHAT_FRAME:AddMessage("  Consecration: |cFFFFD700" .. consecLibram .. "|r")

    -- Show Holy Strike setting
    local hsLibram = (LibramSwapDb.holyStrikeMode == "eternal") and HOLY_STRIKE_ETERNAL_TOWER or HOLY_STRIKE_RADIANCE
    DEFAULT_CHAT_FRAME:AddMessage("  Holy Strike: |cFFFFD700" .. hsLibram .. "|r")
end

-- =====================
-- Hooks (CastSpellByName / CastSpell)
-- =====================
local Original_CastSpellByName = CastSpellByName
function CastSpellByName(spellName, bookType)
    if LibramSwapDb.enabled then
        local base = SplitNameAndRank(spellName)    -- base only for map/throttles
        local libram = ResolveLibramForSpell(base)
        if libram and IsSpellReady(spellName) then  -- rank-aware readiness
            if base == "Judgement" then
                local hp = TargetHealthPct()
                if hp and hp <= 35 then
                    EquipLibramForSpell(base, libram)
                end
            else
                EquipLibramForSpell(base, libram)
            end
        end
    end
    return Original_CastSpellByName(spellName, bookType)
end

local Original_CastSpell = CastSpell
function CastSpell(spellIndex, bookType)
    if LibramSwapDb.enabled and bookType == BOOKTYPE_SPELL then
        local name, rank = GetSpellName(spellIndex, BOOKTYPE_SPELL)
        if name then
            local libram = ResolveLibramForSpell(name)  -- base name for map
            if libram then
                local spec = (rank and rank ~= "") and (name .. "(" .. rank .. ")") or name
                if IsSpellReady(spec) then              -- exact-rank readiness
                    if name == "Judgement" then
                        local hp = TargetHealthPct()
                        if hp and hp <= 35 then
                            EquipLibramForSpell(name, libram)
                        end
                    else
                        EquipLibramForSpell(name, libram)
                    end
                end
            end
        end
    end
    return Original_CastSpell(spellIndex, bookType)
end

-- =====================
-- Slash Commands
-- =====================

-- Main command handler
local function HandleLibramSwapCommand(msg)
    msg = string.lower(trim(msg))
    
    -- Split into command and argument
    local _, _, cmd, arg = string_find(msg, "^(%S*)%s*(.-)$")
    cmd = cmd or ""
    arg = arg or ""
    
    if cmd == "on" then
        LibramSwapDb.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFF00FF00ENABLED|r")
        
    elseif cmd == "off" then
        LibramSwapDb.enabled = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF0000DISABLED|r")

    elseif cmd == "spam" then
        LibramSwapDb.spam = not LibramSwapDb.spam
        local spamStatus = LibramSwapDb.spam and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Swap messages " .. spamStatus)
        
    elseif cmd == "consecration" or cmd == "consec" or cmd == "c" then
        arg = string.lower(arg)
        if arg == "faithful" or arg == "f" then
            LibramSwapDb.consecrationMode = "faithful"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Consecration set to |cFFFFD700" .. CONSECRATION_FAITHFUL .. "|r")
        elseif arg == "farraki" or arg == "z" or arg == "zealot" then
            LibramSwapDb.consecrationMode = "farraki"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Consecration set to |cFFFFD700" .. CONSECRATION_FARRAKI .. "|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Usage: /ls consecration [faithful / farraki]|r")
        end
        
    elseif cmd == "holystrike" or cmd == "hs" then
        arg = string.lower(arg)
        if arg == "radiance" or arg == "r" then
            LibramSwapDb.holyStrikeMode = "radiance"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Holy Strike set to |cFFFFD700" .. HOLY_STRIKE_RADIANCE .. "|r")
        elseif arg == "eternal" or arg == "e" then
            LibramSwapDb.holyStrikeMode = "eternal"
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r Holy Strike set to |cFFFFD700" .. HOLY_STRIKE_ETERNAL_TOWER .. "|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r c||cFFFF5555Usage: /ls holystrike [eternal / radiance]|r")
        end

    elseif cmd == "status" then
        printStatus()
        
    elseif cmd == "help" or cmd == "?" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap] Commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls on|r - Enable libram swapping")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls off|r - Disable libram swapping")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls spam|r - Toggle swap messages on/off")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls consecration [faithful / farraki]|r - Set Consecration libram")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls holystrike [eternal / radiance]|r - Set Holy Strike libram")
        DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD700/ls status|r - Show current settings")
        
    elseif cmd == "" then
        -- Toggle behavior when no argument provided
        LibramSwapDb.enabled = not LibramSwapDb.enabled
        if LibramSwapDb.enabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFF00FF00ENABLED|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF0000DISABLED|r")
        end
        
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]:|r |cFFFF5555Unknown command. Type '/ls help' for usage.|r")
    end
end

-- Register slash command variants
SLASH_LIBRAMSWAP1 = "/libramswap"
SLASH_LIBRAMSWAP2 = "/lswap"
SLASH_LIBRAMSWAP3 = "/ls"
SlashCmdList["LIBRAMSWAP"] = HandleLibramSwapCommand

