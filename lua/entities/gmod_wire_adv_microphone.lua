AddCSLuaFile()

local MIN_VOLUME = 0.02

ENT.Type = "anim"
ENT.Base = "base_wire_entity"
ENT.Author = "stpM64"
ENT.PrintName = "Wire Advanced Microphone"
ENT.Purpose = "Listens to sounds, soundscapes and player voices"
-- Named 'advanced' because 'gmod_wire_microphone' exists in Wire Extras
ENT.WireDebugName = "Advanced Microphone"

-- Note: we listen both serverside and clientside,
-- because some sounds are played clientside only

-- array(Entity(gmod_wire_adv_microphone))
-- Array instead of lookup table because sounds are emitted more often than microphones switched on or off,
-- so iteration is more frequent than insertion/removal.
-- Microphone is live when it is active and at least one active speaker connected to it. 
_WireLiveMicrophones = _WireLiveMicrophones or {}
local LiveMics = _WireLiveMicrophones

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "Active")
    self:NetworkVarNotify("Active", self.OnActiveChanged)
end

function ENT:Initialize()
    if SERVER then
        self:PhysicsInit( SOLID_VPHYSICS )
        self:SetMoveType( MOVETYPE_VPHYSICS )
        self:SetSolid( SOLID_VPHYSICS )

        self.Inputs = WireLib.CreateInputs(self, {
            "Active"
        })

        self._plyCache = WireLib.Sound.NewPlayerDistanceCache(self, WireLib.Sound.VOICE_MAXDIST_SQR)
    end

    -- table(Entity(gmod_wire_adv_speaker), true)
    self._activeSpeakers = {}

    -- Callback not called if 'Active' changes right after creation.
    self:OnActiveChanged(nil, nil, self:GetActive())
end

if SERVER then
    function ENT:Think()
        if not self:GetLive() then return end

        self._plyCache:Think()
    end
end

local function PlayerCanHearPlayersVoice_Hook(listener, talker)
    -- Note: any given speaker can only be connected to one microphone,
    -- so this loops can be considered O(nMic), not O(nMic*nSpeaker)
    for _, mic in ipairs(LiveMics) do
        if not mic._plyCache.PlayersInRange[talker] then goto mic_next end

        for speaker in pairs(mic._activeSpeakers) do
            if IsValid(speaker) and speaker._plyCache.PlayersInRange[listener] then
                return true, false -- Can hear, not in 3D
            end
        end
        ::mic_next::
    end
end

local function Mic_SetLive(self, isLive)
    if not IsValid(self) then
        isLive = false
    else
        if self:GetLive() == isLive then return end
        self:AddEFlags(EFL_FORCE_CHECK_TRANSMIT)
    end

    if isLive then
        if LiveMics[1] == nil then -- Adding first microphone to live list
            hook.Add("PlayerCanHearPlayersVoice", "Wire.AdvMicrophone", PlayerCanHearPlayersVoice_Hook)
        end

        if not table.HasValue(LiveMics, self) then
            table.insert(LiveMics, self)
        end
    else
        if LiveMics[1] ~= nil and LiveMics[2] == nil then -- Removing last microphone from live list
            hook.Remove("PlayerCanHearPlayersVoice", "Wire.AdvMicrophone")
        end

        table.RemoveByValue(LiveMics, self)
    end
end

ENT.SetLive = Mic_SetLive

function ENT:UpdateTransmitState()
    return self:GetLive() and TRANSMIT_ALWAYS or TRANSMIT_PVS
end

function ENT:GetLive()
    return self:GetActive() and not table.IsEmpty(self._activeSpeakers)
end

function ENT:OnActiveChanged(_,_,active)
    if self._activeSpeakers == nil then return end -- This happens on duplication restoration
    if table.IsEmpty(self._activeSpeakers) then return end
    self:SetLive(active)
end

function ENT:TriggerInput( name, value )
    if name == "Active" then
        self:SetActive(value ~= 0)
    end
end

function ENT:SpeakerActivated(speaker)
    if not IsValid(speaker) then return end

    if self:GetActive() then
        -- Must be updated before ._activeSpeakers are updated
        self:SetLive(true)
    end
    self._activeSpeakers[speaker] = true
end

function ENT:SpeakerDeactivated(speaker)
    if self:GetActive() then
        local live = true
        do
            local spk = self._activeSpeakers

            local k1 = next(spk)
            if k1 == nil then -- No active speakers
                live = false
            else
                local k2 = next(spk)
                if k2 == nil and k1 == speaker then -- The only active speaker is 'speaker'
                    live = false
                end
            end
        end

        -- Must be updated before ._activeSpeakers are updated
        self:SetLive(live)
    end
    self._activeSpeakers[speaker] = nil
end

function ENT:OnRemove()
    timer.Simple(0, function()
        if IsValid(self) then return end

        Mic_SetLive(self, false)
    end)
end

local CalculateDistanceGain = WireLib.Sound.CalculateDistanceGain

hook.Add("EntityEmitSound", "Wire.AdvMicrophone", function(snd)
    for _, mic in ipairs(LiveMics) do
        if IsValid(mic) then
            mic:HandleSound(
                snd.SoundName, snd.Volume or 1, snd.Pitch or 100, snd.SoundLevel or 75,
                snd.Entity, snd.Pos, snd.DSP or 0,
                "EmitSound"
            )
        end
    end
end)

hook.Add("Wire_SoundPlay", "Wire.AdvMicrophone", function(name, pos, level, pitch, volume)
    for _, mic in ipairs(LiveMics) do
        if IsValid(mic) then
            mic:HandleSound(
                name, volume, pitch, level,
                nil --[[entity]], pos, 0 --[[DSP]],
                "sound.Play"
            )
        end
    end
end)

function ENT:HandleSound(sndname, volume, pitch, sndlevel, entity, pos, dsp, emittype)
    -- Prevent feedback loops
    if IsValid(entity) and entity:GetClass() == "gmod_wire_adv_speaker" then return end
    if pos == nil and IsValid(entity) then pos = entity:GetPos() end

    if sndlevel ~= 0 and pos ~= nil then
        -- Over-256 values are 'reserved for sounds using goldsrc compatibility attenuation'
        -- I don't care about correct attenuation for HLSource entities,
        -- but I don't want the system to break. 
        if sndlevel >= 256 then sndlevel = sndlevel - 256 end

        volume = volume * CalculateDistanceGain(
            self:GetPos():Distance(pos), sndlevel)
    end

    if volume < MIN_VOLUME then return end
    if volume > 1 then volume = 1 end

    self:ReproduceSound(sndname, volume, pitch, dsp, emittype)
end

function ENT:ReproduceSound(snd, vol, pitch, dsp, emittype)
    for speaker in pairs(self._activeSpeakers) do
        if IsValid(speaker) then
            speaker:ReproduceSound(snd, vol, pitch, dsp, emittype)
        end
    end
end

-- TODO: hook into sound.PlayFile
-- TODO: hook into sound.PlayURL


duplicator.RegisterEntityClass("gmod_wire_adv_microphone", WireLib.MakeWireEnt, "Data")