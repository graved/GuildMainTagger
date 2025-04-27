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

        if name and officernote and officernote ~= "" then
            local shortName = string.gsub(name, "%-.*", "")

            local startIndex, endIndex = string.find(officernote, "Twink")
            if startIndex then
                local mainName = string.sub(officernote, endIndex + 2)
                self.mains[shortName] = mainName
            end
        end
    end

    GuildMainTaggerDB = self.mains
end

if not GuildMainTagger_Original_ChatFrame_OnEvent then
    GuildMainTagger_Original_ChatFrame_OnEvent = ChatFrame_OnEvent
end

function ChatFrame_OnEvent(event)
    if event == "PLAYER_ENTERING_WORLD" or event == "GUILD_ROSTER_UPDATE" then
        GuildMainTagger:UpdateGuildRoster()
    elseif event == "CHAT_MSG_GUILD" then
        if arg1 and arg2 then
            local shortSender = string.gsub(arg2, "%-.*", "")
            local main = GuildMainTagger.mains[shortSender]
            if main and main ~= "" and main ~= shortSender then
                arg1 = "[" .. main .. "]: " .. arg1
            end            
        end
    end

    GuildMainTagger_Original_ChatFrame_OnEvent(event)
end
