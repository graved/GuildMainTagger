----------------------------------------------------------------------
-- GuildMainTagger - Phase 1/2/3
-- Pattern: <Main Charname> anywhere in officer/normal notes
-- Fallback: Officer Note > Normal Note > Local DB
-- Sync: Automatic background sync via addon messages
----------------------------------------------------------------------

local ADDON_PREFIX = "GMainTag"
local DEFAULT_PATTERN = "<Main%s+(.-)>"
local SYNC_DELAY = 15
local THROTTLE_INTERVAL = 0.5
local BULK_SEPARATOR = "|"
local FIELD_SEPARATOR = "\a"

----------------------------------------------------------------------
-- Data Init & Migration
-- NOTE: Must run AFTER SavedVariables are loaded (VARIABLES_LOADED),
--       not at top level, to avoid being overwritten by the game.
----------------------------------------------------------------------
local function GMT_InitDB()
    if not GuildMainTaggerDB then GuildMainTaggerDB = {} end
    if not GuildMainTaggerDB.entries then
        -- Migrate old flat format { ["name"] = "main" }
        local oldEntries = {}
        local hasOld = false
        for k, v in pairs(GuildMainTaggerDB) do
            if type(v) == "string" then
                hasOld = true
                if v ~= "" then
                    oldEntries[k] = { main = v, ts = time(), source = "manual" }
                end
            end
        end
        if hasOld then
            GuildMainTaggerDB = { entries = oldEntries }
        else
            GuildMainTaggerDB.entries = {}
        end
    end
    if not GuildMainTaggerDB.pattern then
        GuildMainTaggerDB.pattern = DEFAULT_PATTERN
    end
    if GuildMainTaggerDB.debug == nil then
        GuildMainTaggerDB.debug = false
    end
end

----------------------------------------------------------------------
-- Runtime State
----------------------------------------------------------------------
local GMT = {}
GMT.noteResolved = {}     -- from guild notes (refreshed on roster update)
GMT.outQueue = {}         -- queued outgoing sync messages
GMT.isSending = false
GMT.syncDone = false
GMT.playerName = nil

----------------------------------------------------------------------
-- Pattern accessor
----------------------------------------------------------------------
local function GetPattern()
    return GuildMainTaggerDB.pattern or DEFAULT_PATTERN
end

----------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------
local function ShortName(fullName)
    if not fullName then return "" end
    return fullName:gsub("%-.*", "")
end

local function Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildMainTagger:|r " .. text)
end

local function Debug(text)
    if GuildMainTaggerDB.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff999999GMT-Debug:|r " .. text)
    end
end

----------------------------------------------------------------------
-- Main Lookup (Priority: Officer Note > Normal Note > DB)
----------------------------------------------------------------------
function GMT:GetMain(name)
    -- 1+2: Note-based (already resolved from roster)
    local noteMain = self.noteResolved[name]
    if noteMain and noteMain ~= "" then
        Debug("GetMain('" .. name .. "') → '" .. noteMain .. "' [note]")
        return noteMain
    end
    -- 3: Local DB
    local entry = GuildMainTaggerDB.entries[name]
    if entry and entry.main and entry.main ~= "" then
        Debug("GetMain('" .. name .. "') → '" .. entry.main .. "' [db/" .. (entry.source or "?") .. "]")
        return entry.main
    end
    Debug("GetMain('" .. name .. "') → nil")
    return nil
end

----------------------------------------------------------------------
-- Guild Roster Parsing
----------------------------------------------------------------------
function GMT:UpdateGuildRoster()
    GuildRoster()
    local numMembers = GetNumGuildMembers()
    wipe(self.noteResolved)
    local pattern = GetPattern()
    Debug("UpdateGuildRoster: " .. numMembers .. " Mitglieder, Pattern='" .. pattern .. "'")

    for i = 1, numMembers do
        local name, _, _, _, _, _, note, officernote = GetGuildRosterInfo(i)
        if name then
            local shortName = ShortName(name)
            local main = nil
            local matchSource = nil

            -- Priority 1: Officer note
            if officernote and officernote ~= "" then
                main = officernote:match(pattern)
                if main then matchSource = "officer" end
            end

            -- Priority 2: Normal note
            if not main and note and note ~= "" then
                main = note:match(pattern)
                if main then matchSource = "note" end
            end

            if main and main ~= "" then
                self.noteResolved[shortName] = main
                Debug("  " .. shortName .. " → " .. main .. " [" .. matchSource .. "]")
                -- Auto-populate DB from notes (don't overwrite manual entries)
                local existing = GuildMainTaggerDB.entries[shortName]
                if not existing or existing.source == "note" or existing.source == "sync" then
                    GuildMainTaggerDB.entries[shortName] = {
                        main = main,
                        ts = time(),
                        source = "note"
                    }
                end
            end
        end
    end
    Debug("UpdateGuildRoster: " .. self:CountTable(self.noteResolved) .. " Zuordnungen aus Notizen")
end

function GMT:CountTable(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

----------------------------------------------------------------------
-- Chat Filter
----------------------------------------------------------------------
ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD", function(self, event, msg, sender, ...)
    local shortSender = ShortName(sender)
    local main = GMT:GetMain(shortSender)

    if not main then
        GMT:UpdateGuildRoster()
        main = GMT:GetMain(shortSender)
    end

    if main and main ~= "" and main ~= shortSender then
        return false, "[" .. main .. "]: " .. msg, sender, ...
    end
    return false, msg, sender, ...
end)

----------------------------------------------------------------------
-- Sync Protocol
----------------------------------------------------------------------
-- Message format: "CMD\afield1\afield2\a..."
-- Commands:
--   SYNC_REQ              - request entries from others
--   SET\aname\amain\ats   - single entry update
--   BULK\aname:main:ts|name:main:ts|...  - bulk entries

local function SerializeEntry(name, entry)
    -- format: name:main:ts:source:author
    return name .. ":" .. entry.main .. ":" .. tostring(entry.ts) .. ":" .. (entry.source or "sync") .. ":" .. (entry.author or "?")
end

local function DeserializeEntry(str)
    -- New format: name:main:ts:source:author
    local name, main, ts, source, author = str:match("^(.-):(.-):(%-?%d+):(%a+):(.+)$")
    if name and main and ts then
        return name, main, tonumber(ts), source, author
    end
    -- Compat format: name:main:ts:source (no author)
    name, main, ts, source = str:match("^(.-):(.-):(%-?%d+):(%a+)$")
    if name and main and ts then
        return name, main, tonumber(ts), source, "?"
    end
    -- Legacy format: name:main:ts
    name, main, ts = str:match("^(.-):(.-):(%d+)$")
    if name and main and ts then
        return name, main, tonumber(ts), "sync", "?"
    end
    return nil
end

function GMT:QueueMessage(msg)
    table.insert(self.outQueue, msg)
end

function GMT:SendNextMessage()
    if #self.outQueue == 0 then
        self.isSending = false
        return
    end
    self.isSending = true
    local msg = table.remove(self.outQueue, 1)
    Debug("SEND: " .. msg:sub(1, 80) .. (#msg > 80 and "..." or ""))
    SendAddonMessage(ADDON_PREFIX, msg, "GUILD")
end

function GMT:BroadcastEntries()
    -- Send all manual and sync entries as BULK messages
    local parts = {}
    local currentMsg = "BULK" .. FIELD_SEPARATOR

    for name, entry in pairs(GuildMainTaggerDB.entries) do
        if entry.source == "manual" or entry.source == "sync" then
            local serialized = SerializeEntry(name, entry)
            -- Check message length limit (255 chars max for addon messages)
            if #currentMsg + #serialized + 1 > 250 then
                -- Send current batch and start new one
                self:QueueMessage(currentMsg)
                currentMsg = "BULK" .. FIELD_SEPARATOR
            end
            if currentMsg == "BULK" .. FIELD_SEPARATOR then
                currentMsg = currentMsg .. serialized
            else
                currentMsg = currentMsg .. BULK_SEPARATOR .. serialized
            end
        end
    end

    if currentMsg ~= "BULK" .. FIELD_SEPARATOR then
        self:QueueMessage(currentMsg)
    end
end

function GMT:RequestSync()
    self:QueueMessage("SYNC_REQ")
end

function GMT:HandleAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    if channel ~= "GUILD" then return end

    local shortSender = ShortName(sender)
    if shortSender == self.playerName then return end -- ignore own messages

    Debug("RECV von " .. shortSender .. ": " .. message:sub(1, 80) .. (#message > 80 and "..." or ""))

    local cmd, payload = message:match("^(.-)%" .. FIELD_SEPARATOR .. "(.*)$")
    if not cmd then
        cmd = message
        payload = nil
    end

    if cmd == "SYNC_REQ" then
        Debug("  → SYNC_REQ von " .. shortSender .. ", sende eigene Eintraege")
        self:BroadcastEntries()

    elseif cmd == "SET" and payload then
        local name, main, ts, source, author = payload:match("^(.-)%" .. FIELD_SEPARATOR .. "(.-)%" .. FIELD_SEPARATOR .. "(%d+)%" .. FIELD_SEPARATOR .. "(.-)%" .. FIELD_SEPARATOR .. "(.-)$")
        if not name then
            -- Legacy format without source/author
            name, main, ts = payload:match("^(.-)%" .. FIELD_SEPARATOR .. "(.-)%" .. FIELD_SEPARATOR .. "(%d+)$")
            source = "sync"
            author = "?"
        end
        if name and main and ts then
            ts = tonumber(ts)
            Debug("  → SET: " .. name .. " → " .. main .. " (ts=" .. tostring(ts) .. ", src=" .. tostring(source) .. ", by=" .. tostring(author) .. ")")
            self:MergeEntry(name, main, ts, source or "sync", author or "?")
        end

    elseif cmd == "BULK" and payload then
        local count = 0
        for part in payload:gmatch("[^%" .. BULK_SEPARATOR .. "]+") do
            local name, main, ts, source, author = DeserializeEntry(part)
            if name and main and ts then
                self:MergeEntry(name, main, ts, source or "sync", author or "?")
                count = count + 1
            end
        end
        Debug("  → BULK: " .. count .. " Eintraege empfangen")
    end
end

function GMT:MergeEntry(name, main, ts, source, author)
    local existing = GuildMainTaggerDB.entries[name]

    -- Note-based entries always have priority (they come from guild roster)
    if existing and existing.source == "note" then
        Debug("  MergeEntry: " .. name .. " ignored (note takes priority)")
        return
    end
    -- Manual entries can only be overwritten by newer manual entries (not plain sync)
    if existing and existing.source == "manual" and source ~= "manual" then
        Debug("  MergeEntry: " .. name .. " ignored (local manual takes priority over " .. source .. ")")
        return
    end
    -- For equal-priority entries, newer timestamp wins
    if existing and existing.ts and existing.ts >= ts then
        Debug("  MergeEntry: " .. name .. " ignored (local entry is newer or equal)")
        return
    end

    Debug("  MergeEntry: " .. name .. " → " .. main .. " [" .. source .. "] accepted")
    GuildMainTaggerDB.entries[name] = {
        main = main,
        ts = ts,
        source = source,
        author = author or "?"
    }
end

function GMT:BroadcastSingleEntry(name, entry)
    local msg = "SET" .. FIELD_SEPARATOR .. name .. FIELD_SEPARATOR .. entry.main .. FIELD_SEPARATOR .. tostring(entry.ts) .. FIELD_SEPARATOR .. (entry.source or "manual") .. FIELD_SEPARATOR .. (entry.author or GMT.playerName or "?")
    self:QueueMessage(msg)
end

----------------------------------------------------------------------
-- Frame & Events
----------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "VARIABLES_LOADED" then
        -- SavedVariables are now available — safe to init/migrate DB
        GMT_InitDB()
        Debug("VARIABLES_LOADED: DB initialisiert")

    elseif event == "PLAYER_ENTERING_WORLD" then
        GMT_InitDB() -- safety: ensure DB is ready even if VARIABLES_LOADED was missed
        GMT.playerName = ShortName(UnitName("player"))
        Debug("PLAYER_ENTERING_WORLD: " .. GMT.playerName)
        GMT:UpdateGuildRoster()
        -- Schedule initial sync after delay
        GMT.syncTimer = SYNC_DELAY
        Debug("Sync scheduled in " .. SYNC_DELAY .. "s")

    elseif event == "GUILD_ROSTER_UPDATE" then
        Debug("GUILD_ROSTER_UPDATE")
        GMT:UpdateGuildRoster()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        GMT:HandleAddonMessage(prefix, message, channel, sender)
    end
end)

-- Throttled message sending via OnUpdate
local elapsed_acc = 0
local sync_elapsed = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    -- Throttled queue processing
    elapsed_acc = elapsed_acc + elapsed
    if elapsed_acc >= THROTTLE_INTERVAL then
        elapsed_acc = 0
        if GMT.isSending or #GMT.outQueue > 0 then
            GMT:SendNextMessage()
        end
    end

    -- Initial sync timer
    if GMT.syncTimer and GMT.syncTimer > 0 then
        GMT.syncTimer = GMT.syncTimer - elapsed
        if GMT.syncTimer <= 0 then
            GMT.syncTimer = nil
            GMT:RequestSync()
            -- Also broadcast our own entries
            GMT:BroadcastEntries()
        end
    end
end)

----------------------------------------------------------------------
-- Slash Commands
----------------------------------------------------------------------
SLASH_GMT1 = "/gmt"
SlashCmdList["GMT"] = function(msg)
    msg = msg or ""
    local args = {}
    for word in msg:gmatch("%S+") do
        table.insert(args, word)
    end

    local command = (args[1] or ""):lower()

    if command == "set" then
        local twink = args[2]
        local main = args[3]
        if not twink or not main then
            Print("Usage: /gmt set <Twinkname> <Mainname>")
            return
        end
        local entry = { main = main, ts = time(), source = "manual", author = GMT.playerName or "?" }
        GuildMainTaggerDB.entries[twink] = entry
        GMT:BroadcastSingleEntry(twink, entry)
        Print(twink .. " → " .. main .. " (saved & broadcasted)")

    elseif command == "remove" or command == "del" then
        local twink = args[2]
        if not twink then
            Print("Usage: /gmt remove <altname>")
            return
        end
        if GuildMainTaggerDB.entries[twink] then
            GuildMainTaggerDB.entries[twink] = nil
            Print(twink .. " removed.")
        else
            Print(twink .. " not found in database.")
        end

    elseif command == "list" then
        Print("Active assignments:")
        local count = 0
        for name, entry in pairs(GuildMainTaggerDB.entries) do
            if entry.main and entry.main ~= "" then
                local src = entry.source or "?"
                local by = entry.author or "?"
                if src == "note" then
                    Print("  " .. name .. " → " .. entry.main .. " [note]")
                else
                    Print("  " .. name .. " → " .. entry.main .. " [" .. src .. ", by: " .. by .. "]")
                end
                count = count + 1
            end
        end
        if count == 0 then
            Print("  (no entries)")
        end

    elseif command == "sync" then
        Print("Starting sync...")
        GMT:RequestSync()
        GMT:BroadcastEntries()

    elseif command == "update" then
        Print("Refreshing guild roster...")
        GMT:UpdateGuildRoster()

    elseif command == "debug" then
        if args[2] and args[2]:lower() == "on" then
            GuildMainTaggerDB.debug = true
            Print("Debug mode |cff00ff00enabled|r")
        elseif args[2] and args[2]:lower() == "off" then
            GuildMainTaggerDB.debug = false
            Print("Debug mode |cffff0000disabled|r")
        else
            -- Toggle
            GuildMainTaggerDB.debug = not GuildMainTaggerDB.debug
            if GuildMainTaggerDB.debug then
                Print("Debug mode |cff00ff00enabled|r")
            else
                Print("Debug mode |cffff0000disabled|r")
            end
        end

    elseif command == "info" then
        Print("Note-resolved (from guild notes):")
        for k, v in pairs(GMT.noteResolved) do
            Print("  " .. k .. " → " .. v)
        end
        Print("DB entries:")
        for k, v in pairs(GuildMainTaggerDB.entries) do
            Print("  " .. k .. " → " .. v.main .. " [" .. (v.source or "?") .. ", by: " .. (v.author or "?") .. ", ts=" .. tostring(v.ts) .. "]")
        end
        Print("Pattern: " .. GetPattern())
        Print("Debug: " .. (GuildMainTaggerDB.debug and "on" or "off"))
        Print("Queue: " .. #GMT.outQueue .. " messages")

    elseif command == "pattern" then
        local newPattern = msg:match("^%S+%s+(.+)$")
        if not newPattern then
            Print("Current pattern: |cffffcc00" .. GetPattern() .. "|r")
            Print("Default pattern: |cffffcc00" .. DEFAULT_PATTERN .. "|r")
            Print("Usage: /gmt pattern <LuaPattern>")
            Print("Examples:")
            Print("  /gmt pattern <Main%s+(.-)>")
            Print("  /gmt pattern <Alt of%s+(.-)>")
            Print("  /gmt pattern %[Main:%s*(.-)%]")
            Print("/gmt pattern reset - Restore default pattern")
            return
        end
        if newPattern:lower() == "reset" then
            GuildMainTaggerDB.pattern = DEFAULT_PATTERN
            Print("Pattern reset to: |cffffcc00" .. DEFAULT_PATTERN .. "|r")
        else
            -- Validate pattern by testing it
            local ok, err = pcall(string.match, "Test <Main Foo>", newPattern)
            if not ok then
                Print("|cffff0000Invalid pattern:|r " .. (err or "unknown error"))
                return
            end
            GuildMainTaggerDB.pattern = newPattern
            Print("Pattern set to: |cffffcc00" .. newPattern .. "|r")
        end
        -- Re-parse roster with new pattern
        GMT:UpdateGuildRoster()

    else
        Print("Commands:")
        Print("  /gmt set <alt> <main>       - Set assignment manually")
        Print("  /gmt remove <alt>           - Remove assignment")
        Print("  /gmt list                   - Show all assignments")
        Print("  /gmt sync                   - Sync with other addon users")
        Print("  /gmt update                 - Refresh guild roster")
        Print("  /gmt pattern [<pat>|reset]  - Show/change search pattern")
        Print("  /gmt debug [on|off]         - Toggle debug mode")
        Print("  /gmt info                   - Show detailed status")
    end
end
