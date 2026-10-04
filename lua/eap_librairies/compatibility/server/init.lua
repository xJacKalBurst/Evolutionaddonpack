--[[
	===========================================================================
	 EAP <-> CAP Compatibility Bridge - Server-side targeted patches
	===========================================================================
	This file is the ONLY place where EAP reaches into a handful of CAP's own
	tools/weapons/entities to patch them in memory, AFTER they have already
	been registered by CAP itself. It never edits a CAP file on disk, and it
	never runs at all unless CAP is detected (Lib.IsCapDetected) - with CAP
	absent, every function below either isn't called or is a silent no-op.

	Three different, narrowly-scoped techniques are used here, all cheaper
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
	   frame is affected.

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

-- Temporarily makes `ent:GetClass()` return `spoofedClass` for the duration
-- of `fn(...)`, then restores it unconditionally (even if fn errors out).
-- The entity's real class, and everything else about it, is untouched.
function EAP.Compat.WithSpoofedClass(ent, spoofedClass, fn, ...)
	if (not IsValid(ent)) then return fn(...) end

	local realGetClass = ent.GetClass;
	ent.GetClass = function() return spoofedClass end

	local results = { pcall(fn, ...) };

	ent.GetClass = realGetClass;

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
	if (not stored or not stored.t or not stored.t[fieldname]) then return end

	local list = stored.t[fieldname];
	for _, v in ipairs(extraValues) do
		if (not table.HasValue(list, v)) then
			table.insert(list, v);
		end
	end
end

function EAP.Compat.ExtendMapField(classname, fieldname, extraKeys)
	local stored = scripted_ents.GetStored(classname);
	if (not stored or not stored.t or not stored.t[fieldname]) then return end

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
	if (not stored or not stored.t) then return end

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

function EAP.Compat.PatchToolLeftClick(toolname)
	local stored = weapons.GetStored("gmod_tool");
	if (not stored or not stored.Tool or not stored.Tool[toolname]) then return end

	local TOOL = stored.Tool[toolname];
	if (TOOL.EAPCompatPatched) then return end
	local RealLeftClick = TOOL.LeftClick;
	if (not RealLeftClick) then return end

	TOOL.LeftClick = function(self, t, ...)
		if (t and IsValid(t.Entity)) then
			local capClass = EAP_TO_CAP[t.Entity:GetClass()];
			if (capClass) then
				return EAP.Compat.WithSpoofedClass(t.Entity, capClass, RealLeftClick, self, t, ...);
			end
		end
		return RealLeftClick(self, t, ...);
	end
	TOOL.EAPCompatPatched = true;
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
	if (not stored or stored.EAPCompatPatched) then return end
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
-- 6. Install everything
-- ===========================================================================

function EAP.Compat.InstallServerPatches()
	if (EAP.Compat.ServerPatchesInstalled) then return end
	EAP.Compat.ServerPatchesInstalled = true;

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

	-- Stools
	for _, toolname in ipairs(SPOOFED_TOOLS) do
		EAP.Compat.PatchToolLeftClick(toolname);
	end

	-- Weapon
	EAP.Compat.PatchVirusWeapon();
end

-- Same two-stage install as the FindByClass bridge in shared/init.lua: try
-- immediately (entities/weapons/tools are already registered by the engine
-- by the time autorun scripts run, so this normally succeeds right away),
-- and again on InitPostEntity as a safety net in case CAP detection itself
-- resolves later than this file loading.
if (Lib.IsCapDetected) then
	EAP.Compat.InstallServerPatches();
end

hook.Add("InitPostEntity", "EAPCompat_InstallServerPatches", function()
	if (Lib.IsCapDetected) then
		EAP.Compat.InstallServerPatches();
	end
end);
