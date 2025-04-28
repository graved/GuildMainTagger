local GuildMainTagger = {}

if not GuildMainTaggerDB then
    GuildMainTaggerDB = {}
end

GuildMainTagger.mains = GuildMainTaggerDB

function GuildMainTagger:UpdateGuildRoster()
    DEFAULT_CHAT_FRAME:AddMessage("GuildMainTagger: Update guild roster and main assignments...")
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

if not GuildMainTagger_Original_ChatFrame_OnEvent then
    GuildMainTagger_Original_ChatFrame_OnEvent = ChatFrame_OnEvent
end

function ChatFrame_OnEvent(event)
    if event == "CHAT_MSG_GUILD" then        
        if arg1 and arg2 then
            local shortSender = string.gsub(arg2, "%-.*", "")
            local main = GuildMainTagger.mains[shortSender]

            if not main then
                GuildMainTagger:UpdateGuildRoster()
                main = GuildMainTagger.mains[shortSender]
            end

            if main and main ~= "" and main ~= shortSender then
                arg1 = "[" .. main .. "]: " .. arg1
            end            
        end
    end

    GuildMainTagger_Original_ChatFrame_OnEvent(event)
end

SLASH_GMT1 = "/gmt"
SlashCmdList["GMT"] = function(msg)
    msg = msg or ""
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end

    local command = string.lower(args[1] or "")

    if command == "update" then        
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