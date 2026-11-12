-- MountFund: påmeldte i guilden sender 1g hver til påmeldte som er 40+ og ikke har riding.
-- Hver karakter kan få støtte én gang, og hver konto betaler hver mottaker én gang.
-- Den med høyest level står først i køen.
local ADDON = ...
local PREFIX          = "MountFund"
local TARGET_LEVEL    = 40
local AMOUNT          = 10000   -- 1 gold i copper
local POSTAGE         = 30      -- porto per brev
local SUBJECT         = "Mount-penger!"
local BODY            = "Fra MountFund-gjengen i guilden. Lykke til med mounten!"
local ROSTER_INTERVAL = 60      -- sekunder mellom hver forespørsel om ny guild-liste
local SEND_TIMEOUT    = 20      -- sekunder vi venter på svar fra posten
local ROSTER_THROTTLE = 10      -- minst så mange sekunder mellom hver forespørsel om guild-liste
local RIDING_SPELLS   = { 33388, 33391, 34090, 34091, 90265 }

local acc                    -- MountFundDB, delt av hele kontoen: paid, pending, skipped, myChars
local char                   -- MountFundChar, per karakter: optedIn, roster, inflight, claimed, done
local participants = {}      -- påmeldte vi har hørt fra denne sesjonen
local outbox = {}            -- meldinger som ikke kom ut (f.eks. i instans)
local verify = {}            -- har bedt om støtte, men levelen er ikke bekreftet i guild-lista ennå
local sendingTo              -- navn på brevet som er underveis
local button

local function Print(msg) print("|cffffd200MountFund:|r " .. msg) end

local function FullName(name)
    if not name or name == "" then return nil end
    if not name:find("-", 1, true) then
        name = name .. "-" .. (GetNormalizedRealmName() or "")
    end
    return name
end

-- På Forever heter karakterer «Fornavn Etternavn», men UnitName("player") gir bare fornavnet.
-- Det fulle navnet hentes derfor fra guild-lista (via GUID) og lagres i char.myName.
local function Me() return (char and char.myName) or FullName(UnitName("player")) end
local function Short(name) return Ambiguate(name, "short") end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- string.lower tar bare A-Z, så vi tar de vanligste spesialbokstavene selv.
local function Lower(s)
    return (s:lower():gsub("Æ", "æ"):gsub("Ø", "ø"):gsub("Å", "å")
                     :gsub("Ä", "ä"):gsub("Ö", "ö"):gsub("Ü", "ü"):gsub("É", "é"))
end

-- Finn et lagret navn uansett store/små bokstaver og med eller uten realm.
local function Resolve(input, ...)
    if not input or input == "" then return nil end
    local want, wantFull = Lower(input), Lower(FullName(input))
    for i = 1, select("#", ...) do
        for name in pairs((select(i, ...))) do
            if Lower(name) == wantFull or Lower(Short(name)) == want then
                return name
            end
        end
    end
end

-- ---------- Kommunikasjon ----------
local function Send(msg)
    if not IsInGuild() then return end
    local r = C_ChatInfo.SendAddonMessage(PREFIX, msg, "GUILD")
    -- Moderne klient returnerer Enum.SendAddonMessageResult (0 = OK).
    if r ~= nil and r ~= true and r ~= 0 then
        table.insert(outbox, msg)
    end
end

local function FlushOutbox()
    if #outbox == 0 or IsInInstance() then return end
    local pending = outbox
    outbox = {}
    for _, msg in ipairs(pending) do Send(msg) end
end

local lastRosterRequest = -ROSTER_THROTTLE
local function RequestRoster()
    -- Strupes, så en spiller som spammer meldinger ikke kan få oss til å spørre hele tiden.
    if not IsInGuild() or GetTime() - lastRosterRequest < ROSTER_THROTTLE then return end
    lastRosterRequest = GetTime()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- ---------- Riding ----------
local function HasRiding()
    if IsPlayerSpell then
        for _, id in ipairs(RIDING_SPELLS) do
            if IsPlayerSpell(id) then return true, "spell " .. id end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader = GetSkillLineInfo(i)
            if name and not isHeader and name:lower():find("riding", 1, true) then
                return true, "skill " .. name
            end
        end
    end
    return false
end

-- ---------- Køen (giversiden) ----------
local function LevelOf(name) return char.roster[name] or TARGET_LEVEL end

-- Kan personen få støtte? Må være 40+ i guild-lista.
local function CanReceive(name)
    local level = char.roster[name]
    return level ~= nil and level >= TARGET_LEVEL
end

-- Top of the food chain: høyest level først, deretter den som har ventet lengst.
local function SortedQueue()
    local list = {}
    for name in pairs(acc.pending) do table.insert(list, name) end
    table.sort(list, function(a, b)
        local la, lb = LevelOf(a), LevelOf(b)
        if la ~= lb then return la > lb end
        local ta, tb = acc.pending[a], acc.pending[b]
        if ta ~= tb then return ta < tb end
        return a < b
    end)
    return list
end

local function NextPending() return SortedQueue()[1] end

local function UpdateButton()
    if not button then return end
    local name = NextPending()
    if not name or not char.optedIn or not MailFrame:IsShown() then button:Hide() return end
    button:SetText(("Send 1g til %s (%d) – %d i kø"):format(Short(name), LevelOf(name), Count(acc.pending)))
    button:SetEnabled(not sendingTo)
    button:Show()
end

local function AddDebt(name)
    name = FullName(name)
    if not char.optedIn or not name or acc.myChars[name] then return end
    if acc.paid[name] or acc.pending[name] or acc.skipped[name] then return end
    acc.pending[name] = time()
    Print(("|cff00ff00%s|r (level %d) mangler riding og ber om mount-støtte. Åpne en postkasse for å sende 1g.")
        :format(Short(name), LevelOf(name)))
    UpdateButton()
end

-- ---------- Mottakersiden ----------
-- Fortell guilden om denne karakteren ber om støtte, eller har fått riding.
local function Announce()
    if not char.claimed then return end
    if char.done then
        Send("DONE")
    elseif char.optedIn then
        Send("ELIG")
    end
end

local function CheckRiding()
    if char.done or not HasRiding() then return end
    char.done = true
    if char.claimed then
        Send("DONE")
        Print("Du har lært riding, gratulerer! Guilden får beskjed, så du blir fjernet fra køen.")
    end
end

-- Be om støtte hvis kravene er oppfylt. Skjer bare én gang per karakter:
-- claimed nullstilles aldri, heller ikke ved /mf leave.
local function TryClaim(level)
    if char.claimed or char.done or not char.optedIn then return false end
    if (level or UnitLevel("player")) < TARGET_LEVEL or HasRiding() then return false end
    char.claimed = time()
    Send("ELIG")
    return true
end

local function SupportStatus()
    if char.claimed then
        return char.done and "brukt (har lært riding)" or "bedt om, venter på gull"
    end
    return char.done and "ikke aktuelt (har riding)" or "ikke brukt"
end

-- ---------- Postkasse-knapp ----------
local function CreateButton()
    if button then return end
    button = CreateFrame("Button", "MountFundSendButton", MailFrame, "UIPanelButtonTemplate")
    button:SetSize(260, 26)
    button:SetPoint("BOTTOM", MailFrame, "TOP", 0, 6)
    button:SetScript("OnClick", function()
        local name = NextPending()
        if not name or sendingTo then return end
        if GetMoney() < AMOUNT + POSTAGE then
            Print("Du har ikke nok gull (1g + porto).")
            return
        end
        ClearSendMail()
        if not SetSendMailMoney(AMOUNT) then
            Print("Klarte ikke legge gullet i brevet.")
            return
        end
        -- Registrer betalingen før brevet sendes, så den ikke går tapt hvis du lukker
        -- postkassen eller mister tilkoblingen før svaret kommer. MAIL_FAILED ruller tilbake.
        sendingTo = name
        char.inflight = name
        acc.paid[name] = time()
        acc.pending[name] = nil
        SendMail(Ambiguate(name, "mail"), SUBJECT, BODY)
        UpdateButton()
        C_Timer.After(SEND_TIMEOUT, function()
            if sendingTo ~= name then return end
            sendingTo = nil
            char.inflight = nil
            Print(("Fikk ikke svar fra posten om brevet til %s. Det regnes som sendt. "
                .. "Hvis gullet ikke er trukket, bruk /mf add %s for å sette personen i køen igjen.")
                :format(Short(name), Short(name)))
            UpdateButton()
        end)
    end)
    button:Hide()
end

-- ---------- Eget navn og oppstart av meldinger ----------
local commsStarted = false

-- Sier fra til guilden at vi er her. Venter til vi vet vårt eget fulle navn,
-- så vi kjenner igjen våre egne meldinger når serveren sender dem tilbake.
local function StartComms()
    if commsStarted then return end
    commsStarted = true
    CheckRiding()
    if char.optedIn then Send("JOIN") end
    Announce()
    Send("PING")
end

local function SetMyName(name)
    char.myName = name
    acc.myChars[name] = true
    acc.pending[name] = nil
    participants[name] = nil
    StartComms()
end

-- ---------- Guild-roster: bekrefter level ----------
local function ScanRoster()
    if not IsInGuild() then return end
    local n = GetNumGuildMembers()
    if not n or n == 0 then return end   -- lista er ikke lastet ennå
    local myGUID = UnitGUID("player")
    for i = 1, n do
        local name, _, _, level, _, _, _, _, _, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
        if name and level and level > 0 then
            name = FullName(name)
            if guid and guid == myGUID and name ~= char.myName then SetMyName(name) end
            char.roster[name] = level
            if verify[name] and CanReceive(name) then
                verify[name] = nil
                AddDebt(name)
            end
        end
    end
    UpdateButton()   -- levelene kan ha endret rekkefølgen i køen
end

-- ---------- Events ----------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

f:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        MountFundDB   = MountFundDB or {}
        MountFundChar = MountFundChar or {}
        acc, char = MountFundDB, MountFundChar
        for _, k in ipairs({ "paid", "pending", "skipped", "myChars" }) do
            acc[k] = acc[k] or {}
        end
        char.roster = char.roster or {}

        -- Flytt data fra v1.1, der alt lå per karakter, over til kontolageret.
        for _, k in ipairs({ "paid", "pending", "skipped" }) do
            if type(char[k]) == "table" then
                for name, v in pairs(char[k]) do
                    if acc[k][name] == nil then acc[k][name] = v end
                end
                char[k] = nil
            end
        end
        if char.eligible then char.claimed = char.claimed or time() end
        char.eligible, char.awaiting, char.eligibleKnown = nil, nil, nil
        for name in pairs(acc.pending) do
            if acc.paid[name] or acc.skipped[name] then acc.pending[name] = nil end
        end

    elseif event == "PLAYER_LOGIN" then
        acc.myChars[Me()] = true
        acc.pending[Me()] = nil
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        for _, e in ipairs({ "PLAYER_LEVEL_UP", "CHAT_MSG_ADDON", "GUILD_ROSTER_UPDATE",
                             "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED",
                             "PLAYER_ENTERING_WORLD" }) do
            f:RegisterEvent(e)
        end
        -- Disse brukes bare til å oppdage at riding er lært; pcall i tilfelle en ikke finnes.
        for _, e in ipairs({ "SPELLS_CHANGED", "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB" }) do
            pcall(f.RegisterEvent, f, e)
        end
        C_Timer.NewTicker(30, FlushOutbox)
        -- Serveren sender ikke ny guild-liste av seg selv når noen dinger, så vi spør jevnlig.
        C_Timer.NewTicker(ROSTER_INTERVAL, RequestRoster)
        C_Timer.After(5, function()
            RequestRoster()
            -- Kjenner vi navnet fra før, kan vi starte med en gang. Ellers venter vi på
            -- guild-lista (SetMyName), med en reserve i tilfelle den ikke kommer.
            if char.myName then StartComms() end
        end)
        C_Timer.After(30, StartComms)
        if char.inflight then
            Print(("Du logget ut mens 1g til %s var underveis. Det regnes som sendt. "
                .. "Sjekk at gullet er trukket; ellers /mf add %s.")
                :format(Short(char.inflight), Short(char.inflight)))
            char.inflight = nil
        end
        if char.optedIn and Count(acc.pending) > 0 then
            Print(("Du har %d mount-gave(r) som venter. Åpne en postkasse."):format(Count(acc.pending)))
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        FlushOutbox()

    elseif event == "SPELLS_CHANGED" or event == "SKILL_LINES_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
        CheckRiding()

    elseif event == "PLAYER_LEVEL_UP" then
        local level = ...
        if level == TARGET_LEVEL and TryClaim(level) then
            Print("Gratz med 40! De påmeldte i guilden får beskjed om å sende deg 1g.")
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= PREFIX or channel ~= "GUILD" then return end
        sender = FullName(sender)
        if sender == Me() then return end

        if msg == "ELIG" then
            -- Personen ber om støtte. Levelen sjekkes i guild-lista, siden hvem som helst kan sende meldingen.
            if not char.optedIn then return end
            if CanReceive(sender) then
                AddDebt(sender)
            else
                verify[sender] = true
                RequestRoster()
            end
        elseif msg == "DONE" then
            -- Personen har lært riding: fjern fra køen, og ikke legg dem inn igjen senere.
            verify[sender] = nil
            if not acc.paid[sender] then acc.skipped[sender] = acc.skipped[sender] or time() end
            if acc.pending[sender] then
                acc.pending[sender] = nil
                Print(("%s har lært riding og er fjernet fra køen."):format(Short(sender)))
                UpdateButton()
            end
        elseif msg == "JOIN" then
            participants[sender] = true
        elseif msg == "LEAVE" then
            participants[sender] = nil
            verify[sender] = nil
            if acc.pending[sender] then   -- avmeldte får ikke støtte (kommer tilbake hvis de melder seg på igjen)
                acc.pending[sender] = nil
                UpdateButton()
            end
        elseif msg == "PING" then
            if char.optedIn then Send("JOIN") end
            Announce()
        end

    elseif event == "GUILD_ROSTER_UPDATE" then
        ScanRoster()

    elseif event == "MAIL_SHOW" then
        CreateButton()
        UpdateButton()

    elseif event == "MAIL_CLOSED" then
        -- sendingTo beholdes: svaret fra posten kan komme etter at postkassen er lukket.
        if button then button:Hide() end

    elseif event == "MAIL_SEND_SUCCESS" then
        if sendingTo then
            Print(("1g sendt til %s. Takk!"):format(Short(sendingTo)))
            sendingTo = nil
            char.inflight = nil
        end
        UpdateButton()

    elseif event == "MAIL_FAILED" then
        if sendingTo then
            acc.paid[sendingTo] = nil
            acc.pending[sendingTo] = time()   -- tilbake i køen
            Print(("Klarte ikke sende til %s – prøv igjen."):format(Short(sendingTo)))
            sendingTo = nil
            char.inflight = nil
        end
        UpdateButton()
    end
end)

-- ---------- Slash-kommandoer ----------
SLASH_MOUNTFUND1 = "/mf"
SLASH_MOUNTFUND2 = "/mountfund"
SlashCmdList.MOUNTFUND = function(input)
    local cmd, arg = (input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "join" then
        char.optedIn = true
        Send("JOIN")
        Send("PING")   -- de som allerede ber om støtte svarer med ELIG
        Print("Du er påmeldt. Du sender 1g til påmeldte guildies som er 40+ og mangler riding.")
        CheckRiding()
        if TryClaim() then
            Print("Du er 40+ og har ikke riding: guilden får beskjed, og du får 1g fra hver påmeldt.")
        elseif char.claimed and not char.done then
            Announce()
            Print("Du har allerede bedt om støtte på denne karakteren. Guilden får beskjed igjen.")
        elseif char.claimed then
            Print("Denne karakteren har allerede fått støtte.")
        elseif char.done then
            Print("Du har allerede riding, så denne karakteren får ikke støtte.")
        else
            Print(("Når du når level %d, får du 1g fra hver påmeldt."):format(TARGET_LEVEL))
        end
    elseif cmd == "leave" then
        char.optedIn = false
        Send("LEAVE")
        Print("Du er avmeldt. Du sender ikke og får ikke gull. Ventende gaver er beholdt (/mf clear for å fjerne).")
    elseif cmd == "who" then
        local list = {}
        if char.optedIn then table.insert(list, Short(Me())) end
        for name in pairs(participants) do
            if name ~= Me() then table.insert(list, Short(name)) end
        end
        table.sort(list)
        Print(("%d påmeldt (online med addon): %s"):format(#list, table.concat(list, ", ")))
    elseif cmd == "queue" then
        local list = SortedQueue()
        if #list == 0 then
            Print("Køen er tom.")
            return
        end
        for i, name in ipairs(list) do
            Print(("%d. %s (level %d)"):format(i, Short(name), LevelOf(name)))
        end
    elseif cmd == "riding" then
        local has, how = HasRiding()
        Print(has and ("Riding funnet (%s)."):format(how) or "Fant ikke riding på denne karakteren.")
        Print("Mount-støtte: " .. SupportStatus())
    elseif cmd == "skip" and arg ~= "" then
        local name = Resolve(arg, acc.pending)
        if not name then
            Print(("Fant ingen «%s» i køen."):format(arg))
            return
        end
        acc.pending[name] = nil
        acc.skipped[name] = time()      -- huskes, så personen ikke kommer tilbake i køen
        Print("Fjernet " .. Short(name) .. " fra køen.")
        UpdateButton()
    elseif cmd == "clear" then
        for name in pairs(acc.pending) do acc.skipped[name] = time() end
        wipe(acc.pending)
        Print("Køen er tømt.")
        UpdateButton()
    elseif (cmd == "add" or cmd == "test") and arg ~= "" then
        if not char.optedIn then
            Print("Du må være påmeldt først (/mf join).")
            return
        end
        local name = Resolve(arg, char.roster, acc.paid, acc.skipped) or FullName(arg)
        acc.paid[name] = nil
        acc.skipped[name] = nil
        AddDebt(name)
        if acc.pending[name] then
            Print("NB: dette er ekte gjeld. Klikker du på knappen i postkassen, sendes ekte gull.")
        else
            Print(("Kunne ikke legge til %s (er det en av dine egne karakterer?)."):format(Short(name)))
        end
    else
        Print(("Status: %s, %d i kø, %d betalt totalt (hele kontoen). Din mount-støtte: %s.")
            :format(char.optedIn and "|cff00ff00påmeldt|r" or "|cffff0000ikke påmeldt|r",
                    Count(acc.pending), Count(acc.paid), SupportStatus()))
        Print("/mf join | leave | who | queue | riding | skip <navn> | clear | add <navn>")
    end
end
