local GuildMainTagger = {}

if not GuildMainTaggerDB then
    GuildMainTaggerDB = {}
end

GuildMainTagger.mains = GuildMainTaggerDB

function GuildMainTagger:UpdateGuildRoster()    
    GuildRoster()
    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name, rank, rankIndex, level, class, zone, note, officernote, online = GetGuildRosterInfo(i)

        if name then
            local shortName = string.gsub(name, "%-.*", "")
            if officernote and officernote ~= "" then
                local startIndex, endIndex = string.find(officernote, "Twink")
                if startIndex then
                    local mainName = string.sub(officernote, endIndex + 2)
                    self.mains[shortName] = mainName
                else
                    self.mains[shortName] = ""
                end
            else
                self.mains[shortName] = ""
            end
        end
    end

    GuildMainTaggerDB = self.mains
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD", function(self, event, msg, sender, ...)
    local shortSender = string.gsub(sender, "%-.*", "")
    local main = GuildMainTagger.mains[shortSender]

    if not main then
        GuildMainTagger:UpdateGuildRoster()
        main = GuildMainTagger.mains[shortSender]
    end

    if main and main ~= "" and main ~= shortSender then
        return false, "[" .. main .. "]: " .. msg, sender, ...
    end
    return false, msg, sender, ...
end)

local GuildMainTagger_Frame = CreateFrame("Frame")
GuildMainTagger_Frame:RegisterEvent("GUILD_ROSTER_UPDATE")
GuildMainTagger_Frame:RegisterEvent("PLAYER_ENTERING_WORLD")
GuildMainTagger_Frame:SetScript("OnEvent", function(self, event)
    GuildMainTagger:UpdateGuildRoster()
end)

SLASH_GMT1 = "/gmt"
SlashCmdList["GMT"] = function(msg)
    msg = msg or ""
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end

    local command = string.lower(args[1] or "")

    if command == "update" then
        DEFAULT_CHAT_FRAME:AddMessage("GuildMainTagger: Update guild roster and main assignments...")
        GuildMainTagger:UpdateGuildRoster()
    elseif command == "debug" then
        DEFAULT_CHAT_FRAME:AddMessage("GuildMainTagger: Show current main assignments...")
        for k, v in pairs(GuildMainTagger.mains) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. k .. " → " .. v)
        end        
    else
        DEFAULT_CHAT_FRAME:AddMessage("GuildMainTagger: Available commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /gmt update  - Update guild roster and main assignments")
        DEFAULT_CHAT_FRAME:AddMessage("  /gmt debug   - Show current main assignments")
    end
end
