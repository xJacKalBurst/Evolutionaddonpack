--[[
	===========================================================================
	 EAP <-> CAP Compatibility Bridge - Server-side targeted patches
	===========================================================================
	This file is the ONLY place where EAP reaches into a handful of CAP's own
	tools/weapons/entities to patch them in memory, AFTER they have already
	been registered by CAP itself. It never edits a CAP file on disk, and it
	never runs at all unless CAP is detected (Lib.IsCapDetected) - with CAP
	absent, every function below either isn't called or is a silent no-op.

	Four different, narrowly-scoped techniques are used here, all cheaper
	than a global GetClass() override (rejected earlier for this project -
	see shared/init.lua's header):

	1. Per-call GetClass() spoofing (EAP.Compat.WithSpoofedClass)
	   A handful of CAP stools/weapons decide what to do by comparing
	   t.Entity:GetClass() (or a traced entity's GetClass()) against a CAP
	   literal such as "stargate_universe" or "stargate_orlin". We wrap just
	   that one call (one LeftClick, one SpawnProp) so the entity reports its
	   CAP-equivalent class ONLY for the duration of that single call, then
	   restores its real GetClass immediately after. The entity's class is
	   never actually changed, and nothing else observing it during that
	   frame is affected. The exact same technique is also applied in the
	   OTHER direction (section 4b): several of EAP's OWN stools gate on an
	   EAP class literal the same way, so they get the mirrored spoof too
	   (CAP entity -> reports its EAP-equivalent class for that one call).

	2. Static data-table extension (EAP.Compat.ExtendArrayField / ExtendMapField)
	   A couple of CAP entities keep a plain Lua list/map of "classes I
	   recognize" as instance data (ENT.GateList, ENT.ValidGates, etc). These
	   aren't functions, so there's nothing to wrap - we just add the EAP
	   equivalents directly into that same table once, after CAP registers
	   it, via scripted_ents.GetStored(class).t.

	3. Function replacement (EAP.Compat.PatchRampGateFinder)
	   The CAP ramp entities' GateFinder() method uses a hand-rolled pattern
	   match (v:GetClass():find("stargate_*")) that only ever matches CAP's
	   own "stargate_..." classes. We replace that one method (same
	   scripted_ents.GetStored(class).t mechanism) with an equivalent version
	   that also recognizes EAP's "sg_..." classes, keeping every other
	   behavior of the entity untouched.

	4. Scripting-backend registry merges (section 6 below)
	   EAP's and CAP's E2/ExpAdv2/Wire-gate/Starfall stargate extension
	   files live at the same path in both addons, so only one of them ever
	   actually loads - the other is fully shadowed, not just overridden
	   function-by-function. For the one function in all four that breaks
	   because of this (stargateGetRingAngle), we reach into whichever
	   backend's own registry ends up holding it (wire_expression2_funcs,
	   GateActions, the ExpAdv2 "stargate" component, Starfall's
	   SF.Entities.Methods) and overwrite that one entry with a version
	   that recognizes both class families - same "patch the registry after
	   the fact" principle as the other three techniques, just applied to a
	   table slot instead of a Lua method.

	Known, accepted limitation: a few places inside CAP's own Think()/logic
	compare an entity's class directly in-line against a CAP literal in a way
	that can't be patched by any of the three techniques above without
	reimplementing that function's full body (e.g. gate_nuke's supergate
	shutdown branch: `elseif class == "stargate_supergate" then`). Those are
	left as-is: they simply won't trigger for an EAP supergate caught in a
	CAP gate_nuke's blast radius. This is a deliberate trade-off to avoid
	duplicating CAP's internal logic inside this bridge.
]]--

EAP = EAP or {};
EAP.Compat = EAP.Compat or {};

-- Reuses the two-way class map built in shared/init.lua (loaded before this
-- file - see eap_include.lua).
local CAP_TO_EAP = EAP.Compat.CapToEap or {};
local EAP_TO_CAP = EAP.Compat.EapToCap or {};

-- ===========================================================================
-- 1. Per-call GetClass() spoofing helper
-- ===========================================================================

-- IMPORTANT: a per-instance assignment (`ent.GetClass = function() ... end`)
-- has ZERO effect in GMod - `Entity:GetClass()` is resolved through the
-- shared Entity metatable at the engine level, not through per-instance Lua
-- table storage the way an ordinary custom field (`ent.Foo = 123`) is. This
-- was confirmed empirically (diagnostic logging showed ent:GetClass() still
-- returning the real class immediately after the per-instance assignment),
-- and is why every tool/weapon patch in this file that relies on this
-- helper previously had no effect in-game despite installing with no
-- warnings.
--
-- The fix has to replace the function slot on the METATABLE itself
-- (FindMetaTable("Entity").GetClass), which is what :GetClass() actually
-- resolves through for every entity. To keep this as narrowly-scoped as
-- the global override already rejected for this project (see this file's
-- header), the replacement:
--   - only returns the spoofed class for the ONE entity passed in (an
--     identity check - `self == ent`), every other entity's GetClass() is
--     untouched and goes straight to the previous implementation;
--   - is installed and removed strictly around the single synchronous
--     pcall(fn, ...) below (one LeftClick, one SpawnProp) - there is no
--     ongoing per-frame cost, unlike a persistent hook;
--   - saves and restores whatever was on the metatable slot at entry/exit
--     (`previousGetClass`), rather than assuming it's always the engine's
--     own original function. This makes nested/re-entrant calls (e.g. one
--     spoofed LeftClick that itself triggers another spoofed call before
--     returning - same entity or a different one) resolve correctly: each
--     call's wrapper falls back to exactly what was installed before it,
--     so unwinding always peels back to the right layer instead of two
--     nested calls clobbering a single shared "real function" variable.
function EAP.Compat.WithSpoofedClass(ent, spoofedClass, fn, ...)
	if (not IsValid(ent)) then return fn(...) end

	local entMeta = FindMetaTable("Entity");
	local previousGetClass = entMeta.GetClass;

	entMeta.GetClass = function(self)
		if (self == ent) then return spoofedClass end
		return previousGetClass(self);
	end

	local results = { pcall(fn, ...) };

	entMeta.GetClass = previousGetClass;

	if (not results[1]) then
		error(results[2], 0);
	end

	return unpack(results, 2);
end

-- ===========================================================================
-- 2. Static data-table extension helpers
-- ===========================================================================

function EAP.Compat.ExtendArrayField(classname, fieldname, extraValues)
	local stored = scripted_ents.GetStored(classname);
	if (not stored or not stored.t or not stored.t[fieldname]) then
		MsgN("[EAP Compat] WARNING: couldn't find CAP entity '"..classname.."' (field '"..fieldname.."') to extend - was it really registered yet?");
		return;
	end

	local list = stored.t[fieldname];
	for _, v in ipairs(extraValues) do
		if (not table.HasValue(list, v)) then
			table.insert(list, v);
		end
	end
end

function EAP.Compat.ExtendMapField(classname, fieldname, extraKeys)
	local stored = scripted_ents.GetStored(classname);
	if (not stored or not stored.t or not stored.t[fieldname]) then
		MsgN("[EAP Compat] WARNING: couldn't find CAP entity '"..classname.."' (field '"..fieldname.."') to extend - was it really registered yet?");
		return;
	end

	local map = stored.t[fieldname];
	for _, k in ipairs(extraKeys) do
		map[k] = true;
	end
end

-- ===========================================================================
-- 3. Ramp GateFinder() replacement
-- ===========================================================================
-- Same behavior as CAP's own GateFinder (self.Gate = the last matching gate
-- found among constrained ents), just matching "sg_..." in addition to
-- "stargate_...". `excludeClass`, when given, is skipped exactly like CAP's
-- own ramp_2 skips "stargate_dhd" (there is no EAP equivalent to exclude).

local function IsBridgedGateClass(class, excludeClass)
	if (excludeClass and class == excludeClass) then return false end
	return class:find("stargate") ~= nil or class:find("^sg_") ~= nil;
end

function EAP.Compat.PatchRampGateFinder(classname, excludeClass)
	local stored = scripted_ents.GetStored(classname);
	if (not stored or not stored.t) then
		MsgN("[EAP Compat] WARNING: couldn't find CAP entity '"..classname.."' to patch its GateFinder() - was it really registered yet?");
		return;
	end

	stored.t.GateFinder = function(self)
		for _, v in pairs(StarGate.GetConstrainedEnts(self.Entity, 2) or {}) do
			if (IsValid(v) and IsBridgedGateClass(v:GetClass(), excludeClass)) then
				self.Gate = v;
			end
		end
	end
end

-- ===========================================================================
-- 4. CAP stool LeftClick patch (uses the spoofing helper from section 1)
-- ===========================================================================
-- Covers every CAP stool confirmed to gate its LeftClick behavior on
-- t.Entity:GetClass() matching a CAP gate literal: bearing, floorchevron
-- (both check for "stargate_universe"), goauld_iris and stargate_iris (both
-- exclude "stargate_orlin" - without this patch, an EAP Orlin gate is NOT
-- excluded, which is a minor permissiveness bug this patch also fixes), and
-- supergate_dhd (checks for "stargate_supergate"). stargate_dhd.lua was
-- checked and does NOT need this (its LeftClick doesn't compare classes).

local SPOOFED_TOOLS = { "bearing", "floorchevron", "goauld_iris", "stargate_iris", "supergate_dhd" };

-- Shared by both directions (section 4 and 4b below), and also by the
-- InitializeTools/existing-weapon re-patching in section 4c: wraps a given
-- TOOL object's LeftClick (whichever table it lives in - the class-level
-- template, or a per-weapon-instance copy) using the given class map.
local function WrapToolLeftClickObj(TOOL, classMap)
	if (not TOOL) then return end
	if (TOOL.EAPCompatPatched) then return end
	local RealLeftClick = TOOL.LeftClick;
	if (not RealLeftClick) then return end

	TOOL.LeftClick = function(self, t, ...)
		if (t and IsValid(t.Entity)) then
			local mappedClass = classMap[t.Entity:GetClass()];
			if (mappedClass) then
				return EAP.Compat.WithSpoofedClass(t.Entity, mappedClass, RealLeftClick, self, t, ...);
			end
		end
		return RealLeftClick(self, t, ...);
	end
	TOOL.EAPCompatPatched = true;
end

function EAP.Compat.PatchToolLeftClick(toolname)
	local stored = weapons.GetStored("gmod_tool");
	if (not stored or not stored.Tool or not stored.Tool[toolname]) then
		MsgN("[EAP Compat] WARNING: couldn't find CAP tool '"..toolname.."' to patch - was it really registered yet?");
		return;
	end
	WrapToolLeftClickObj(stored.Tool[toolname], EAP_TO_CAP);
end

-- ===========================================================================
-- 4b. EAP stool LeftClick patch (mirror of section 4, other direction)
-- ===========================================================================
-- Section 4 above only covers CAP's OWN stools gating on a CAP class
-- literal. EAP ships several of its own stools that independently gate on
-- an EAP class literal the exact same way - these were never patched
-- before, which is why e.g. EAP's own "gatebearing" tool refuses an EAP
-- Universe gate's CAP counterpart with its "not a Universe stargate" error
-- (t.Entity:GetClass():find("sg_universe") - confirmed in
-- weapons/gmod_tool/stools/gatebearing.lua). Exact same spoofing
-- technique, just mirrored: CAP_TO_EAP instead of EAP_TO_CAP, and EAP's own
-- tool names instead of CAP's.
--
-- Confirmed by grepping every EAP stool under weapons/gmod_tool/stools/:
--   - gatebearing, floor_chevron: hard-require the target class to contain
--     "sg_universe" - blocking bug, fixed by this patch.
--   - supergatedhd: hard-require the target class to equal "sg_supergate"
--     exactly - blocking bug, fixed by this patch.
--   - goauldiris, iris_sgc, iris_atlantis, iris_infinity: accept any
--     t.Entity.IsStargate (already addon-agnostic - CAP entities set that
--     flag too), but exclude only the literal "sg_orlin" - without this
--     patch, a CAP Orlin gate (stargate_orlin) is NOT excluded, mirroring
--     the same minor permissiveness bug section 4's comment already
--     documents for CAP's own iris tools. Included here for parity.
--   - stargatedhd: no gate-class literal at all - already addon-agnostic,
--     nothing to patch.

local SPOOFED_EAP_TOOLS = {
	"gatebearing", "floor_chevron", "supergatedhd",
	"goauldiris", "iris_sgc", "iris_atlantis", "iris_infinity",
};

function EAP.Compat.PatchEapToolLeftClick(toolname)
	local stored = weapons.GetStored("gmod_tool");
	if (not stored or not stored.Tool or not stored.Tool[toolname]) then
		MsgN("[EAP Compat] WARNING: couldn't find EAP tool '"..toolname.."' to patch - was it really registered yet?");
		return;
	end
	WrapToolLeftClickObj(stored.Tool[toolname], CAP_TO_EAP);
end

-- ===========================================================================
-- 4c. Re-patch on InitializeTools + sweep existing toolguns
-- ===========================================================================
-- Sections 4 and 4b above only patch the CLASS-LEVEL template stored at
-- weapons.GetStored("gmod_tool").Tool[toolname]. That template is NOT what
-- LeftClick actually runs on at click time: Facepunch's own
-- gmod_tool/shared.lua SWEP:InitializeTools() - called every time a player
-- is given/re-equips the tool gun - does
--     temp[k] = table.Copy(v); ... self.Tool = temp
-- i.e. makes a FRESH per-weapon-instance COPY of every entry in the
-- class-level template, once, at that moment, and from then on LeftClick is
-- called on that per-instance copy, never on the template again.
--
-- table.Copy() copies a function VALUE by reference (Lua functions aren't
-- deep-cloned), so a copy made AFTER our class-level patch above still
-- points at our wrapper - fine. But a copy made BEFORE our patch (e.g. the
-- local player's tool gun, handed to them during their own spawn/loadout,
-- which can easily happen earlier than our InitPostEntity-timed install)
-- keeps the ORIGINAL, unpatched LeftClick forever for that weapon
-- instance - which is exactly why bearing/floorchevron/etc. kept failing
-- in both directions even though the template patch installed with no
-- warning. Two extra steps close this gap:
--
--   a) wrap SWEP:InitializeTools itself, so every COPY made from now on
--      (every future tool-gun pickup/respawn) gets re-wrapped right after
--      the copy is made, regardless of whether the template was patched
--      in time;
--   b) immediately sweep every "gmod_tool" weapon entity that already
--      exists right now (e.g. already in a player's hands) and re-wrap its
--      current per-instance copy directly, so weapons handed out before
--      this file ran are fixed retroactively too.

local TOOLNAME_TO_MAP = {};
for _, toolname in ipairs(SPOOFED_TOOLS) do TOOLNAME_TO_MAP[toolname] = EAP_TO_CAP; end
for _, toolname in ipairs(SPOOFED_EAP_TOOLS) do TOOLNAME_TO_MAP[toolname] = CAP_TO_EAP; end

function EAP.Compat.PatchToolInitializeTools()
	local stored = weapons.GetStored("gmod_tool");
	if (not stored) then
		MsgN("[EAP Compat] WARNING: couldn't find 'gmod_tool' SWEP table to patch InitializeTools - was it really registered yet?");
		return;
	end
	if (stored.EAPCompatInitPatched) then return end

	local RealInitializeTools = stored.InitializeTools;
	if (RealInitializeTools) then
		stored.InitializeTools = function(self, ...)
			RealInitializeTools(self, ...);
			if (self.Tool) then
				for toolname, classMap in pairs(TOOLNAME_TO_MAP) do
					if (self.Tool[toolname]) then
						WrapToolLeftClickObj(self.Tool[toolname], classMap);
					end
				end
			end
		end
	end

	stored.EAPCompatInitPatched = true;
end

function EAP.Compat.RepatchExistingToolguns()
	for _, wep in ipairs(ents.FindByClass("gmod_tool")) do
		if (IsValid(wep) and wep.Tool) then
			for toolname, classMap in pairs(TOOLNAME_TO_MAP) do
				if (wep.Tool[toolname]) then
					WrapToolLeftClickObj(wep.Tool[toolname], classMap);
				end
			end
		end
	end
end

-- ===========================================================================
-- 5. v_virus (Gate Virus) weapon patch
-- ===========================================================================
-- SpawnProp() traces where the player is looking and only proceeds if the
-- traced entity's class contains "stargate_". We re-run the same trace
-- ahead of the real call (same inputs, same result - a trace has no side
-- effects) purely to know whether to spoof, then spoof only for that call.

function EAP.Compat.PatchVirusWeapon()
	local stored = weapons.GetStored("v_virus");
	if (not stored) then
		MsgN("[EAP Compat] WARNING: couldn't find CAP weapon 'v_virus' to patch - was it really registered yet?");
		return;
	end
	if (stored.EAPCompatPatched) then return end
	local RealSpawnProp = stored.SpawnProp;
	if (not RealSpawnProp) then return end

	stored.SpawnProp = function(self, ...)
		local p = self.Owner;
		if (IsValid(p)) then
			local tr = util.TraceLine(util.GetPlayerTrace(p));
			if (IsValid(tr.Entity)) then
				local capClass = EAP_TO_CAP[tr.Entity:GetClass()];
				if (capClass) then
					return EAP.Compat.WithSpoofedClass(tr.Entity, capClass, RealSpawnProp, self, ...);
				end
			end
		end
		return RealSpawnProp(self, ...);
	end
	stored.EAPCompatPatched = true;
end

-- ===========================================================================
-- 6. Scripting-backend function merges (E2 / ExpAdv2 / Wire gates / Starfall)
-- ===========================================================================
-- EAP's and CAP's own extension files for these 4 scripting backends
-- (lua/entities/gmod_wire_expression2/core/custom/stargate.lua,
-- lua/expadv/components/custom/stargate.lua, lua/wire/gates/stargate.lua,
-- lua/starfall/libs_sv/stargate.lua) live at the EXACT SAME path in both
-- addons. Garry's Mod's virtual filesystem only exposes ONE file per
-- addon-relative path across every mounted addon - whichever addon wins
-- the mount-order priority is the only one that ever actually runs; the
-- other addon's identically-named file is fully invisible and never
-- executes at all. This is NOT a "last one registered wins" clash (which
-- would already be a pointer we could wrap, like ents.FindByClass) - it's
-- a full file-level shadow, so there is nothing of the losing addon's to
-- wrap directly.
--
-- Both files are near-identical (EAP's is historically a fork of CAP's),
-- and grepping both confirms only ONE function in all four actually
-- hard-codes a literal class whitelist: stargateGetRingAngle() (entity +
-- wirelink variants, x1 for the Wire gate node). Every other function only
-- checks the addon-agnostic `this.IsStargate` flag, so it keeps working no
-- matter which file wins the shadow.
--
-- The fix stays true to the same principle as the ents.FindByClass wrap in
-- shared/init.lua: reach into whichever registry each backend keeps its
-- registered functions in, AFTER it has been populated (InitPostEntity,
-- same as the rest of this file), and overwrite just that one entry with a
-- version that recognizes both class families - entirely from this file,
-- no new file added anywhere in CAP's, Wire's, ExpAdv2's or Starfall's own
-- folders. An earlier version of this fix mistakenly shipped new files
-- inside those addons' own "custom"/"gates"/"libs_sv" extension folders -
-- functionally equivalent, but a needless departure from "nothing outside
-- this file reaches into another addon's structure". Replaced by this.

local MERGED_RING_ANGLE_CLASSES = {
	"sg_movie","sg_sg1","sg_infinity","sg_universe",
	"stargate_movie","stargate_sg1","stargate_infinity","stargate_universe",
};

local function IsMergedUniverseClass(class)
	return class == "sg_universe" or class == "stargate_universe";
end

-- 6a. Expression 2: wire_expression2_funcs[signature][3] is the actual
-- Lua function E2 chips call for that signature. "e:" = entity this-arg,
-- "xwl:" = wirelink this-arg (Wire's own type codes).
function EAP.Compat.MergeE2StargateGetRingAngle()
	if (not wire_expression2_funcs) then return end

	local entityEntry = wire_expression2_funcs["stargateGetRingAngle(e:)"];
	if (entityEntry) then
		entityEntry[3] = function(self, args)
			local this = args[1];
			if not IsValid(this) or not this.IsStargate or not(isOwner(self,this) or self.player:IsAdmin()) then return -1 end
			if (not table.HasValue(MERGED_RING_ANGLE_CLASSES, this:GetClass())) then return -1 end
			if (IsMergedUniverseClass(this:GetClass())) then
				if (IsValid(this.Gate)) then
					local angle = tonumber(math.NormalizeAngle(this.Gate:GetLocalAngles().r));
					if (angle<0) then angle = angle+360; end;
					return angle;
				end
				return -1;
			else
				if (IsValid(this.Ring)) then
					local angle = tonumber(math.NormalizeAngle(this.Ring:GetLocalAngles().r));
					if (angle<0) then angle = angle+360; end;
					return angle;
				end
				return -1;
			end
		end
	else
		MsgN("[EAP Compat] WARNING: E2 function 'stargateGetRingAngle(e:)' not found to merge - was Wire/E2 loaded yet?");
	end

	local wirelinkEntry = wire_expression2_funcs["stargateGetRingAngle(xwl:)"];
	if (wirelinkEntry) then
		wirelinkEntry[3] = function(self, args)
			local this = args[1];
			if not IsValid(this) or not this.IsStargate then return -1 end
			if (not table.HasValue(MERGED_RING_ANGLE_CLASSES, this:GetClass())) then return -1 end
			if (IsMergedUniverseClass(this:GetClass())) then
				if (IsValid(this.Gate)) then
					local angle = tonumber(math.NormalizeAngle(this.Gate:GetLocalAngles().r));
					if (angle<0) then angle = angle+360; end;
					return angle;
				end
				return -1;
			else
				if (IsValid(this.Ring)) then
					local angle = tonumber(math.NormalizeAngle(this.Ring:GetLocalAngles().r));
					if (angle<0) then angle = angle+360; end;
					return angle;
				end
				return -1;
			end
		end
	else
		MsgN("[EAP Compat] WARNING: E2 function 'stargateGetRingAngle(xwl:)' not found to merge - was Wire/E2 loaded yet?");
	end
end

-- 6b. Wire gates: GateActions is the global, shared registry both addons'
-- "wire/gates/stargate.lua" write their gate node definitions into.
function EAP.Compat.MergeWireGateGetRingAngle()
	if (not GateActions or not GateActions["GetRingAngle"]) then
		MsgN("[EAP Compat] WARNING: wire gate 'GetRingAngle' not found to merge - was Wire loaded yet?");
		return;
	end

	local gate = GateActions["GetRingAngle"];
	gate.output = function(gateself, Ent)
		if not IsValid(Ent) or not Ent.IsStargate then return -1 end
		if (not table.HasValue(MERGED_RING_ANGLE_CLASSES, Ent:GetClass())) then return -1 end
		if (IsMergedUniverseClass(Ent:GetClass())) then
			if (IsValid(Ent.Gate)) then
				local angle = tonumber(math.NormalizeAngle(Ent.Gate:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return -1;
		else
			if (IsValid(Ent.Ring)) then
				local angle = tonumber(math.NormalizeAngle(Ent.Ring:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return -1;
		end
	end
end

-- 6c. Expression Advanced 2: fetch the already-registered "stargate"
-- component and re-add the two VM functions onto it - AddVMFunction()
-- itself just overwrites the entry for that name+signature, same as E2's
-- registerFunction() does, so calling it again from here is the merge.
function EAP.Compat.MergeExpAdv2StargateGetRingAngle()
	if (not WireLib or not EXPADV) then return end
	local Component = EXPADV.GetComponent("stargate");
	if (not Component) then
		MsgN("[EAP Compat] WARNING: ExpAdv2 'stargate' component not found to merge - was ExpAdv2 loaded yet?");
		return;
	end

	Component:AddVMFunction( "stargateGetRingAngle", "e:", "n", function( Context, Trace, Entity )
		if not IsValid(Entity) or not Entity.IsStargate or not EXPADV.PPCheck(Context,Entity) then return -1 end
		if (not table.HasValue(MERGED_RING_ANGLE_CLASSES, Entity:GetClass())) then return -1 end
		if (IsMergedUniverseClass(Entity:GetClass())) then
			if (IsValid(Entity.Gate)) then
				local angle = tonumber(math.NormalizeAngle(Entity.Gate:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return -1;
		else
			if (IsValid(Entity.Ring)) then
				local angle = tonumber(math.NormalizeAngle(Entity.Ring:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return -1;
		end
	end)
	Component:AddFunctionHelper( "stargateGetRingAngle", "e:", "Returns stargate ring angle." )

	Component:AddVMFunction( "stargateGetRingAngle", "wl:", "n", function( Context, Trace, Entity )
		if not IsValid(Entity) or not Entity.IsStargate then return -1 end
		if (not table.HasValue(MERGED_RING_ANGLE_CLASSES, Entity:GetClass())) then return -1 end
		if (IsMergedUniverseClass(Entity:GetClass())) then
			if (IsValid(Entity.Gate)) then
				local angle = tonumber(math.NormalizeAngle(Entity.Gate:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return -1;
		else
			if (IsValid(Entity.Ring)) then
				local angle = tonumber(math.NormalizeAngle(Entity.Ring:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return -1;
		end
	end)
	Component:AddFunctionHelper( "stargateGetRingAngle", "wl:", "Returns stargate ring angle." )
end

-- 6d. Starfall: SF.Entities.Methods is the shared methods table both
-- addons' "starfall/libs_sv/stargate.lua" write stargateGetRingAngle()
-- into - reassigning it here overwrites it exactly the same way loading a
-- second file would.
function EAP.Compat.MergeStarfallStargateGetRingAngle()
	if (not SF or not SF.Entities) then return end

	local ents_metatable = SF.Entities.Metatable;
	local ents_methods = SF.Entities.Methods;
	local unwrap = SF.Entities.Unwrap;

	if (not ents_methods or not ents_methods.stargateGetRingAngle) then
		MsgN("[EAP Compat] WARNING: Starfall 'stargateGetRingAngle' method not found to merge - was Starfall loaded yet?");
		return;
	end

	local function canModify(ply, ent)
		return SF.Entities.GetOwner(ent) == ply or game.SinglePlayer() and ent.GateSpawnerSpawned;
	end

	ents_methods.stargateGetRingAngle = function(self)
		SF.CheckType( self, ents_metatable );
		local this = unwrap( self );
		if not canModify(SF.instance.player,this) then return false, "Insufficient permissions" end
		if not this.IsStargate then return false, "entity is not stargate" end
		if (not table.HasValue(MERGED_RING_ANGLE_CLASSES, this:GetClass())) then return false, "Stargate should be sg1, movie, infinity or universe class" end
		if (IsMergedUniverseClass(this:GetClass())) then
			if (IsValid(this.Gate)) then
				local angle = tonumber(math.NormalizeAngle(this.Gate:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return false;
		else
			if (IsValid(this.Ring)) then
				local angle = tonumber(math.NormalizeAngle(this.Ring:GetLocalAngles().r));
				if (angle<0) then angle = angle+360; end;
				return angle;
			end
			return false;
		end
	end
end

-- ===========================================================================
-- 7. Dialing-UI address-list bridge (cross-addon net messages)
-- ===========================================================================
-- Each addon's dial/computer/DHD menu (lua/.../vgui/stargatemenus.lua) keeps
-- its OWN private client-side table of known gates (a local upvalue, not a
-- global - not reachable from here), populated only by listening for its
-- OWN net messages. A gate's ENT:SendGateInfo()/ENT:RefreshGateList() (one
-- call per field: address, group, name, private, blocked, locale, galaxy,
-- class, pos) broadcasts those net messages - but EAP and CAP picked
-- DIFFERENT net-string names for the exact same mechanism:
--   EAP: "RefreshGatesList" / "RemoveGatesFromList" / "RemoveGatesList"
--   CAP: "RefreshGateList"  / "RemoveGateFromList"   / "RemoveGateList"
-- (names, payload layout - EntIndex/Class/IsGroupStargate/field/type/value -
-- and call sites confirmed identical in both addons' sg_base/stargate_base
-- modules/lib.lua and server/spawner.lua). So a CAP gate's broadcast is
-- never heard by EAP's client code (wrong net-string name) and vice versa:
-- the FindByClass bridge (shared/init.lua) already made each addon's code
-- SEE the other's gates, but this networking layer is a second, separate
-- hop that bridge never touched, which is why no address from the other
-- addon ever reaches either side's dial UI.
--
-- Since the wire format is identical, the fix doesn't need to touch either
-- vgui file (would mean editing EAP's own non-compatibility code, and we
-- have no legal access to CAP's client table anyway): we wrap each addon's
-- ENT:RefreshGateList/ENT:RemoveGateFromList to ALSO re-send the exact same
-- payload under the OTHER addon's net-string name, right after the real
-- call. Both addons already register all four net-strings themselves
-- (util.AddNetworkString, called unconditionally by each addon's own
-- lib.lua) whenever they're both loaded, so there's nothing new to
-- register here.

function EAP.Compat.PatchGateAddressBroadcast()
	local eapStored = scripted_ents.GetStored("sg_base");
	local capStored = scripted_ents.GetStored("stargate_base");
	if (not eapStored or not eapStored.t or not capStored or not capStored.t) then
		MsgN("[EAP Compat] WARNING: couldn't find 'sg_base' and/or 'stargate_base' to bridge the address-list net messages - were they really registered yet?");
		return;
	end
	if (eapStored.t.EAPCompatAddressBridgePatched) then return end

	local function ResendRefresh(netName, self, type, value, typ, pl)
		if (not IsValid(self.Entity)) then return end
		net.Start(netName);
		net.WriteInt(self.Entity:EntIndex(), 16);
		net.WriteString(self.Entity:GetClass());
		net.WriteBit(self.IsGroupStargate);
		net.WriteString(type);
		net.WriteString(typ or "");
		if (typ == "bool") then
			net.WriteBit(value);
		elseif (typ == "vector") then
			net.WriteVector(value);
		else
			net.WriteString(value);
		end
		if (pl) then
			net.Send(pl);
		else
			net.Broadcast();
		end
	end

	local RealEapRefresh = eapStored.t.RefreshGateList;
	if (RealEapRefresh) then
		eapStored.t.RefreshGateList = function(self, type, value, typ, pl)
			RealEapRefresh(self, type, value, typ, pl);
			ResendRefresh("RefreshGateList", self, type, value, typ, pl); -- CAP's name
		end
	end

	local RealCapRefresh = capStored.t.RefreshGateList;
	if (RealCapRefresh) then
		capStored.t.RefreshGateList = function(self, type, value, typ, pl)
			RealCapRefresh(self, type, value, typ, pl);
			ResendRefresh("RefreshGatesList", self, type, value, typ, pl); -- EAP's name
		end
	end

	local function ResendRemove(netName, self)
		if (not IsValid(self.Entity)) then return end
		net.Start(netName);
		net.WriteInt(self.Entity:EntIndex(), 16);
		net.Broadcast();
	end

	local RealEapRemove = eapStored.t.RemoveGateFromList;
	if (RealEapRemove) then
		eapStored.t.RemoveGateFromList = function(self)
			RealEapRemove(self);
			ResendRemove("RemoveGateFromList", self); -- CAP's name
		end
	end

	local RealCapRemove = capStored.t.RemoveGateFromList;
	if (RealCapRemove) then
		capStored.t.RemoveGateFromList = function(self)
			RealCapRemove(self);
			ResendRemove("RemoveGatesFromList", self); -- EAP's name
		end
	end

	eapStored.t.EAPCompatAddressBridgePatched = true;
	capStored.t.EAPCompatAddressBridgePatched = true;
end

-- Rarer case: the gatespawner's "Restored" full-list-reset broadcast (map
-- save/load edge case, lua/.../server/spawner.lua), a plain global function
-- rather than an ENT method - same "wrap, call through, also re-fire under
-- the other name" principle, just without the metatable/BaseClass angle.
function EAP.Compat.PatchGateSpawnerRestoredBroadcast()
	if (not Lib.GateSpawner or not StarGate.GateSpawner) then
		MsgN("[EAP Compat] WARNING: couldn't find Lib.GateSpawner and/or StarGate.GateSpawner to bridge the gatespawner-restore net messages - were they really loaded yet?");
		return;
	end
	if (EAP.Compat.EAPCompatGateSpawnerRestoredPatched) then return end

	local RealEapRestored = Lib.GateSpawner.Restored;
	if (RealEapRestored) then
		Lib.GateSpawner.Restored = function(...)
			RealEapRestored(...);
			net.Start("RemoveGateList"); -- CAP's name
			net.WriteBit(true);
			net.Broadcast();
		end
	end

	local RealCapRestored = StarGate.GateSpawner.Restored;
	if (RealCapRestored) then
		StarGate.GateSpawner.Restored = function(...)
			RealCapRestored(...);
			net.Start("RemoveGatesList"); -- EAP's name
			net.WriteBit(true);
			net.Broadcast();
		end
	end

	EAP.Compat.EAPCompatGateSpawnerRestoredPatched = true;
end

-- ===========================================================================
-- 8. Install everything
-- ===========================================================================

function EAP.Compat.InstallServerPatches()
	-- gate_nuke: let it recognize EAP gates/DHDs the same way it already
	-- recognizes CAP's own (its hard-coded "stargate_supergate" branch is
	-- the one known limitation documented in this file's header).
	EAP.Compat.ExtendArrayField("gate_nuke", "GateList", {
		"sg_sg1", "sg_atlantis", "sg_universe", "sg_orlin", "sg_movie", "sg_tollan", "sg_infinity",
	});
	EAP.Compat.ExtendArrayField("gate_nuke", "DHDList", {
		"dhd_milk", "dhd_atl", "dhd_uni", "dhd_inf",
	});

	-- sgc_server: ValidGates is the "this class can register with an SGC
	-- Server" allow-list.
	EAP.Compat.ExtendMapField("sgc_server", "ValidGates", {
		"sg_sg1", "sg_infinity", "sg_movie",
	});

	-- Ramps: GateFinder() replacement so each ramp also recognizes an EAP
	-- gate parked/constrained on it.
	EAP.Compat.PatchRampGateFinder("future_ramp");
	EAP.Compat.PatchRampGateFinder("goauld_ramp");
	EAP.Compat.PatchRampGateFinder("icarus_ramp");
	EAP.Compat.PatchRampGateFinder("sgc_ramp");
	EAP.Compat.PatchRampGateFinder("ramp_2", "stargate_dhd");
	-- ramp.lua and sgu_ramp.lua were checked and have no GateFinder to patch.

	-- Stools (CAP's own, patched to recognize EAP gates)
	for _, toolname in ipairs(SPOOFED_TOOLS) do
		EAP.Compat.PatchToolLeftClick(toolname);
	end

	-- Stools (EAP's own, patched to recognize CAP gates - mirror direction)
	for _, toolname in ipairs(SPOOFED_EAP_TOOLS) do
		EAP.Compat.PatchEapToolLeftClick(toolname);
	end

	-- Stools: make sure the patch actually reaches weapons already in
	-- players' hands, and every future tool-gun pickup from now on (see
	-- section 4c's header comment for why the two patches above, by
	-- themselves, are not enough).
	EAP.Compat.PatchToolInitializeTools();
	EAP.Compat.RepatchExistingToolguns();

	-- Weapon
	EAP.Compat.PatchVirusWeapon();

	-- Scripting backends (E2 / ExpAdv2 / Wire gates / Starfall)
	EAP.Compat.MergeE2StargateGetRingAngle();
	EAP.Compat.MergeWireGateGetRingAngle();
	EAP.Compat.MergeExpAdv2StargateGetRingAngle();
	EAP.Compat.MergeStarfallStargateGetRingAngle();

	-- Dialing UI: make each addon's gate address broadcasts also reach the
	-- other addon's client-side dial/computer/DHD menu (see section 7's
	-- header comment - different net-string names for an identical wire
	-- format).
	EAP.Compat.PatchGateAddressBroadcast();
	EAP.Compat.PatchGateSpawnerRestoredBroadcast();
end

-- Unlike shared/init.lua's ents.FindByClass wrap (which only touches a
-- function pointer and works no matter when it runs), everything in this
-- file reaches into CAP's own tools/weapons/entities via
-- scripted_ents.GetStored()/weapons.GetStored() - which only returns
-- something once CAP has actually registered them. Per Garry's Mod's
-- documented Lua loading order, lua/autorun/* (which is where this file is
-- loaded from, through eap_include.lua) runs BEFORE lua/weapons/* and
-- lua/entities/* are scanned and registered - so calling
-- InstallServerPatches() immediately here would always find CAP's tools
-- and entities missing and silently do nothing. (An earlier version of
-- this file tried exactly that "immediate + InitPostEntity" two-stage
-- install, and a same-session single-shot guard on the immediate call that
-- found nothing blocked the InitPostEntity retry from ever running - this
-- is why bearing/floorchevron/goauld_iris/stargate_iris/supergate_dhd/
-- v_virus/gate_nuke/sgc_server/the ramps all silently failed to get
-- patched in practice. Fixed by only installing on InitPostEntity, which
-- fires after every entity on the map - and therefore every addon's
-- registration - is done.)
MsgN("[EAP Compat] server/init.lua file loaded (Lib.IsCapDetected right now = "..tostring(Lib.IsCapDetected)..")");

hook.Add("InitPostEntity", "EAPCompat_InstallServerPatches", function()
	MsgN("[EAP Compat] InitPostEntity fired (Lib.IsCapDetected = "..tostring(Lib.IsCapDetected)..") - "..(Lib.IsCapDetected and "installing server patches now." or "CAP not detected, skipping."));
	if (Lib.IsCapDetected) then
		EAP.Compat.InstallServerPatches();
		MsgN("[EAP Compat] InstallServerPatches() finished running.");
	end
end);
