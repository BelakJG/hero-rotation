--- ============================ HEADER ============================
--- ======= LOCALIZE =======
-- Addon
local addonName, addonTable = ...
-- HeroDBC
local DBC        = HeroDBC.DBC
-- HeroLib
local HL         = HeroLib
local Cache      = HeroCache
local Unit       = HL.Unit
local Player     = Unit.Player
local Pet        = Unit.Pet
local Target     = Unit.Target
local Spell      = HL.Spell
local MultiSpell = HL.MultiSpell
local Item       = HL.Item
-- HeroRotation
local HR         = HeroRotation
local Cast       = HR.Cast
local AoEON      = HR.AoEON
local CDsON      = HR.CDsON
-- Lua


--- ============================ CONTENT ============================
--- ======= APL LOCALS =======

-- Define S/I for spell and item arrays
local S = Spell.Shaman.Restoration
local I = Item.Shaman.Restoration

-- Create table to exclude above trinkets from On Use function
local OnUseExcludes = {
}


-- GUI Settings
local Everyone = HR.Commons.Everyone
local Shaman = HR.Commons.Shaman
local Settings = {
  General = HR.GUISettings.General,
  Commons = HR.GUISettings.APL.Shaman.Commons,
  Elemental = HR.GUISettings.APL.Shaman.Restoration
}

--local DeeptremorStoneEquipped = Player:HasLegendaryEquipped(131)

--HL:RegisterForEvent(function()
--  DeeptremorStoneEquipped = Player:HasLegendaryEquipped(131)
--end, "PLAYER_EQUIPMENT_CHANGED")

HL:RegisterForEvent(function()
  S.LavaBurst:RegisterInFlight()
end, "LEARNED_SPELL_IN_TAB")
S.LavaBurst:RegisterInFlight()

local function num(val)
  if val then return 1 else return 0 end
end

local function bool(val)
  return val ~= 0
end

-- These variables are rotational modifiers parameters.
local NumEnemiesInCombat
local NumEnemiesInLargestCluster
local ActiveFlameshocks
local RefreshableFlameshocks
local FightTimeRemaining
local CoreUnitInLargestCluster
local BestFlameshockUnit
local SplashedEnemiesTable

-- We keep track of total enemies in combat, as well as a bunch of parameters around the encounter.
local function BattlefieldSnapshot()
  NumEnemiesInCombat = 0
  NumEnemiesInLargestCluster = 0
  ActiveFlameshocks = 0
  RefreshableFlameshocks = 0
  FightTimeRemaining = 0
  SplashedEnemiesTable = {}
  CoreUnitInLargestCluster = nil
  BestFlameshockUnit = nil

  local min_flameshock_duration = 999
  local max_hp = 0
  if AoEON() then
    for _, Enemy in pairs(Player:GetEnemiesInRange(40)) do
      -- NOTE: the IsDummy() check will assume that you ARE IN COMBAT with all dummies on screen, so zoom in camera to "work around" for testing.
      if Enemy:AffectingCombat() or Enemy:IsDummy() then
        -- Update enemies-in-combat count.
        NumEnemiesInCombat = NumEnemiesInCombat + 1

        -- Update flameshock data on your targets. 
        -- Select as "best flameshock unit" the enemy with minimum fs duration remaining, breaking ties by highest remaining health.
        local fs_duration = Enemy:DebuffRemains(S.FlameShockDebuff)
        if fs_duration > 0 then
          ActiveFlameshocks = ActiveFlameshocks + 1
        end
        if fs_duration < 5 then
          RefreshableFlameshocks = RefreshableFlameshocks + 1
        end
        if fs_duration < min_flameshock_duration then
          min_flameshock_duration = fs_duration
          BestFlameshockUnit = Enemy
        end
        if fs_duration == 0 and Enemy:Health() > max_hp then
          max_hp = Enemy:Health()
          BestFlameshockUnit = Enemy
        end

        -- Update splashed enemy data. This actually assigns to each unit a GROUP of splashed units, called a splash_cluster.
        -- We can use this to choose when to chain lightning; specifically, we want to CL when any one of these
        -- groups has two or more units in it.
        -- TODO: sometimes we don't want to CL because the second or third targets are immune or irrelevant, for example third boss halls adds
        -- double TODO: figure out the spell value of CL's maelstrom gen versus CL's maelstrom gen + damage (squad leader pulls in spires?)
        -- We can't currently figure out which target is the "center" of the group.
        -- BUG: If you just call Enemy:GetEnemiesInSplashRange(), chain lightning and earthquake seem to double count?!
        -- We do a stupid O(N^2) deduplication. This is probably dumb but works okay for small N.
        local potentially_duplicated_splashes = Enemy:GetEnemiesInSplashRange(10)
        local splash_cluster = {}
        for _, potential_dupe in pairs(potentially_duplicated_splashes) do
          local dupe_found = false
          for _, unique_guy in pairs(splash_cluster) do
            if potential_dupe:GUID() == unique_guy:GUID() then
              dupe_found = true
              break
            end
          end
          if not dupe_found then table.insert(splash_cluster, potential_dupe) end
        end
        SplashedEnemiesTable[Enemy] = splash_cluster
        if #splash_cluster > NumEnemiesInLargestCluster then
          NumEnemiesInLargestCluster = #splash_cluster
          CoreUnitInLargestCluster = Enemy
        end

        -- Update FightTimeRemaining
        if not Enemy:TimeToDieIsNotValid() and not Enemy:IsUserCycleBlacklisted() then
          FightTimeRemaining = math.max(FightTimeRemaining, Enemy:TimeToDie())
        end
      end
    end
  else
    -- AoEON is disabled, so only care about the primary target
    NumEnemiesInCombat = 1

    -- Update flameshock data
    local fs_duration = Target:DebuffRemains(S.FlameShockDebuff)
    if fs_duration > 0 then
      ActiveFlameshocks = 1
    end
    if fs_duration < 5 then
      RefreshableFlameshocks = 1
    end
    BestFlameshockUnit = Target

    -- Update "splash data"
    NumEnemiesInLargestCluster = 1
    CoreUnitInLargestCluster = Target

    -- Update FightTimeRemaining
    if not Target:TimeToDieIsNotValid() and not Target:IsUserCycleBlacklisted() then
      FightTimeRemaining = Target:TimeToDie()
    end
  end
end

-- Some spells aren't castable while moving or if you're currently casting them, so we handle that behavior here.
-- Additionally, lavaburst isn't castable without a charge or a proc.
local function IsViable(spell)
  if spell == nil then
    return nil
  end
  local BaseCheck = spell:IsCastable() and spell:IsReady()
  if spell == S.LightningBolt or spell == S.ChainLightning then
    local MovementPredicate = (not Player:IsMoving() or Player:BuffUp(S.SpiritwalkersGraceBuff))
    return BaseCheck and MovementPredicate
  elseif spell == S.LavaBurst then
    local MovementPredicate = (not Player:IsMoving() or Player:BuffUp(S.LavaSurgeBuff) or Player:BuffUp(S.SpiritwalkersGraceBuff))
    local a = Player:BuffUp(S.LavaSurgeBuff)
    local b = (not Player:IsCasting(S.LavaBurst) and S.LavaBurst:Charges() >= 1)
    local c = (Player:IsCasting(S.LavaBurst) and S.LavaBurst:Charges() == 2)
    -- d) TODO: you are casting something else, but you will have >= 1 charge at the end of the cast of the spell
    --    Implementing d) will require something like LavaBurstChargesFractionalP(); this is not hard but I haven't done it.
    return BaseCheck and MovementPredicate and (a or b or c)
  else
    return BaseCheck
  end
end


local function Precombat()
  if IsViable(S.Fleshcraft) then
    if Cast(S.Fleshcraft, nil, Settings.Commons.DisplayStyle.Covenant) then return "Precombat Fleshcraft" end
  end
  if IsViable(S.LavaBurst) and not Player:IsCasting(S.LavaBurst) then
    if Cast(S.LavaBurst, nil, nil, not Target:IsSpellInRange(S.LavaBurst)) then return "Precombat Lavaburst" end
  end
  if Player:IsCasting(S.LavaBurst) and S.FlameShock:CooldownRemains() == 0 then 
    if Cast(S.FlameShock, nil, nil, not Target:IsSpellInRange(S.FlameShock)) then return "Precombat Flameshock" end
  end
end

local function Cooldowns()
  local TrinketToUse = Player:GetUseableTrinkets(OnUseExcludes)
  if TrinketToUse then
    if Cast(TrinketToUse, nil, Settings.Commons.DisplayStyle.Trinkets) then return "Trinket CD" end
  end
  if Player:IsMoving() and S.SpiritwalkersGrace:IsCastable() then
    if Cast(S.SpiritwalkersGrace, nil, Settings.Commons.DisplayStyle.SpiritwalkersGrace) then return "Suggest SWG" end
  end
  if IsViable(S.ChainHarvest) then
    if Cast(S.ChainHarvest, nil, Settings.Commons.DisplayStyle.Covenant) then return "Chain Harvest CD" end
  end
  if IsViable(S.FaeTransfusion) then
    if Cast(S.FaeTransfusion, nil, Settings.Commons.DisplayStyle.Covenant) then return "Fae Transfusion CD" end
  end
end

local function NumFlameShocksToMaintain()
  return min(NumEnemiesInLargestCluster, 2) -- fallthrough when no combat?
end

local function ApplyFlameShock()
  if S.FlameShock:CooldownRemains() > 0 or BestFlameshockUnit == nil then return nil end
  if BestFlameshockUnit:GUID() == Target:GUID() then
    if Cast(S.FlameShock, nil, nil, not Target:IsInRange(40)) then return "main-target flameshock"; end
  else
    if HR.CastLeftNameplate(BestFlameshockUnit, S.FlameShock) then return "off-target flameshock"; end
  end
  return nil
end

local function SingleTargetAndSpreadCleaveBuilder()
  if IsViable(S.LavaBurst) then
    return S.LavaBurst, false
  elseif IsViable(S.LightningBolt) then
    return S.LightningBolt, true
  end
  -- End up here when there are no castable builders for a st/spread cleave situation (on the move, no LB charges)
  return nil, false
end

local function AOEBuilder()
  if IsViable(S.ChainLightning) then
    return S.ChainLightning, true
  elseif IsViable(S.LavaBurst) then 
    return S.LavaBurst, true
  end
  -- End up here when there are no castable builders for a stacked cleave situation (on the move, no LB charges)
  return nil, false
end

local function CoreRotation()
  local DebugMessage

  -- Keep minimum number of flameshocks up
  if ActiveFlameshocks < NumFlameShocksToMaintain() then
    DebugMessage = ApplyFlameShock()
    if DebugMessage then return DebugMessage end;
  end

  local builder, prefer_fs_refresh = nil, false
  if NumEnemiesInLargestCluster < 3 then 
    builder, prefer_fs_refresh = SingleTargetAndSpreadCleaveBuilder() 
  else
    builder, prefer_fs_refresh = AOEBuilder() 
  end

  -- Refresh flameshocks when the builder is low priority.
  if prefer_fs_refresh and RefreshableFlameshocks > 0 and ActiveFlameshocks <= NumFlameShocksToMaintain() then
    DebugMessage = ApplyFlameShock()
    if DebugMessage then return DebugMessage end;
  end
  
  -- If you have a non-nil + viable builder, then you should cast it!
  if builder ~= nil and IsViable(builder) then
    if Cast(builder) then return "Building Maelstrom with optimal Builder (AOE)" end
  end
  if builder == nil then
    -- Try to refresh flameshocks
    DebugMessage = ApplyFlameShock()
    if DebugMessage then return "Refreshing Flame Shock because we cannot build or spend" end
    if Cast(S.FrostShock) then return "Casting Frost Shock because we cannot build or spend or refresh flame shock" end
  end

  return nil
end

--- ======= MAIN =======
local function APL()
  -- Generalized Data Updates (per frame)
  BattlefieldSnapshot()

  local DebugMessage
  if Everyone.TargetIsValid() then
    if not Player:AffectingCombat() then
      DebugMessage = Precombat();
      if DebugMessage then return DebugMessage end;
    end
    Everyone.Interrupt(30, S.WindShear, Settings.Commons.OffGCDasOffGCD.WindShear, false);

    DebugMessage = Cooldowns()
    if DebugMessage then return DebugMessage end;

    DebugMessage = CoreRotation()
    if DebugMessage then return DebugMessage end;

    -- This is actually an "error" state, we should always be able to frost shock.
    HR.CastAnnotated(S.FrostShock, false, "ERR");
  end
end

local function Init()
  HR.Print("Restoration Shaman rotation is currently a work in progress.")
end

HR.SetAPL(264, APL, Init)
