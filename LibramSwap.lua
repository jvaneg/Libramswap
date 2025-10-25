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

local LibramSwapEnabled = false
local lastEquippedLibram = nil

-- Global (generic) throttle for GCD-based swaps
local lastSwapTime = 0

-- =====================
-- Config
-- =====================
-- Keep original generic throttle for GCD spells
local SWAP_THROTTLE_GENERIC = 1.48

-- Per-spell throttles (begin applying AFTER the first successful swap of that spell)
local PER_SPELL_THROTTLE = {
    ["Judgement"]       = 7.8,
}

-- Consecration libram choices
local CONSECRATION_FAITHFUL = "Libram of the Faithful"
local CONSECRATION_FARRAKI  = "Libram of the Farraki Zealot"

-- Runtime toggle for which libram to use on Consecration ("faithful" or "farraki")
-- (Session-only; add to SavedVariables in the TOC if you want it to persist between logins.)
LibramConsecrationMode = LibramConsecrationMode or "faithful"

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
    ["Concentration Aura"]            = "Libram of Truth",
    ["Retribution Aura"]              = "Libram of Truth",
    ["Sanctity Aura"]                 = "Libram of Truth",
    ["Fire Resistance Aura"]          = "Libram of Truth",
    ["Frost Resistance Aura"]         = "Libram of Truth",
    ["Shadow Resistance Aura"]        = "Libram of Truth",
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

-- Extract numeric itemID from an item link (1.12 safe)
local function ItemIDFromLink(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
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
                    local _, _, bracketName = string.find(link, "%[(.-)%]")
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
    end
end)

-- =====================
-- Rank-aware spell parsing
-- =====================
-- Split a spec like "Holy Light(Rank 4)" → base="Holy Light", reqRank="Rank 4"
-- Tolerant of spaces and case ("rank", "RANK") and extra whitespace.
local function SplitNameAndRank(spellSpec)
    if not spellSpec then return nil, nil end
    local base, rnum = string.match(spellSpec, "^(.-)%s*%(%s*[Rr][Aa][Nn][Kk]%s*(%d+)%s*%)%s*$")
    if base then
        return (string.gsub(base, "%s+$", "")), ("Rank " .. rnum)
    end
    return spellSpec, nil
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
                if link and string_find(link, itemName, 1, true) then
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
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF5555[LibramSwap]: Swap blocked (interaction window open).|r")
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
        -- Reduce spam if desired by commenting this out
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]: Equipped|r " .. itemName .. " |cFF888888(" .. spellName .. ")|r")
        return true
    end
    return false
end

local function ResolveLibramForSpell(spellName)
    -- Special handling: Consecration libram is user-selectable
    if spellName == "Consecration" then
        local mode = (LibramConsecrationMode == "farraki") and "farraki" or "faithful"
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

-- =====================
-- Hooks (CastSpellByName / CastSpell)
-- =====================
local Original_CastSpellByName = CastSpellByName
function CastSpellByName(spellName, bookType)
    if LibramSwapEnabled then
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
    if LibramSwapEnabled and bookType == BOOKTYPE_SPELL then
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
SLASH_LIBRAMSWAP1 = "/libramswap"
SlashCmdList["LIBRAMSWAP"] = function()
    LibramSwapEnabled = not LibramSwapEnabled
    if LibramSwapEnabled then
        DEFAULT_CHAT_FRAME:AddMessage("LibramSwap ENABLED", 0, 1, 0)
    else
        DEFAULT_CHAT_FRAME:AddMessage("LibramSwap DISABLED", 1, 0, 0)
    end
end

-- Toggle/select libram used for Consecration
SLASH_CONSECLIBRAM1 = "/conseclibram"
SLASH_CONSECLIBRAM2 = "/clibram"
SlashCmdList["CONSECLIBRAM"] = function(msg)
    msg = string.lower(tostring(msg or ""))
    if msg == "faithful" or msg == "f" then
        LibramConsecrationMode = "faithful"
    elseif msg == "farraki" or msg == "z" or msg == "zealot" then
        LibramConsecrationMode = "farraki"
    elseif msg == "toggle" or msg == "" then
        LibramConsecrationMode = (LibramConsecrationMode == "faithful") and "farraki" or "faithful"
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]: /conseclibram [faithful|farraki|toggle]|r")
        return
    end
    local active = (LibramConsecrationMode == "farraki") and CONSECRATION_FARRAKI or CONSECRATION_FAITHFUL
    DEFAULT_CHAT_FRAME:AddMessage("|cFFAAAAFF[LibramSwap]: Consecration libram set to|r " .. active)
end
