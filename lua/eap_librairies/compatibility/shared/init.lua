--[[
	===========================================================================
	 EAP <-> CAP Compatibility Bridge
	===========================================================================
	This folder (lua/eap_librairies/compatibility/) is the ONLY part of EAP
	that is aware CAP (Carter's Addon Pack, github.com/RafaelDeJongh/cap)
	might also be installed. Nothing outside this folder references CAP in
	any way: the rest of EAP is 100% self-contained and works identically
	whether this folder exists or not, and whether CAP is installed or not.

	This bridge NEVER modifies a single file belonging to CAP, and NEVER
	modifies EAP's own class-comparison logic either (no "or X=='stargate_...'"
	added anywhere in sg_base/dhdbase/etc.) - the base stays exactly as clean
	as it was before this folder existed. It works purely by:
	  1. Wrapping the engine's `ents.FindByClass` so a search for one
	     addon's class also returns matches from the other addon, for every
	     entity family we know about (stargates, DHDs, rings, ring panels,
	     obelisks, transporters, ships).
	  2. Doing nothing at all if CAP isn't detected (see Lib.IsCapDetected
	     in eap_librairies/shared/init.lua) - zero overhead, zero behavior
	     change, when EAP runs alone.

	It deliberately does NOT try to make `entity:GetClass()` lie depending
	on who's asking (CAP vs EAP) globally - that would require inspecting
	the Lua call stack on every single GetClass() call in the game (GetClass()
	is called constantly, including in Think() hooks), which is not an
	acceptable performance trade-off on a live server. The practical
	consequence: CAP's own type-specific behavior (Universe 3-char
	addressing, Orlin always-fast-dial, Atlantis no-ring, etc.) will not
	automatically trigger when CAP's code is looking at an EAP entity found
	through this bridge, since CAP will still see it report its real EAP
	class - and the reverse is also true (EAP's own type-specific checks,
	e.g. sg_base's "self.Entity:GetClass()=='sg_universe'", will not trigger
	for a CAP Universe gate either). The one narrow exception is the handful
	of CAP tools patched in server/init.lua, where the "lie" is scoped to a
	single entity for a single click (see that file's header comment).

	This whole folder is written so it could be lifted out and shipped as
	its own standalone addon later, if someone wants to maintain it that
	way - it has no dependency on anything else in eap_librairies/ beyond
	Lib.IsCapDetected and the EAP/Lib globals already set up before this
	file loads.
]]--

EAP = EAP or {};
EAP.Compat = EAP.Compat or {};

-- ===========================================================================
-- 1. Class family map (two-way)
-- ===========================================================================
-- Every pair of (CAP class, EAP class) that represents "the same kind of
-- thing". Every class name below was checked against both repositories'
-- actual lua/entities/ folder names (which is what GMod registers as the
-- scripted-ent classname) rather than assumed - a few pairs from an earlier
-- draft of this file turned out to be wrong (notably the Atlantis
-- transporter) and are corrected here.
--
-- Stargates are also covered by a prefix rule below (so any new gate type
-- added to either addon under the usual stargate_*/sg_* naming is picked up
-- automatically), but we still list them here explicitly so exact
-- (non-wildcard) ents.FindByClass("stargate_universe") calls are bridged
-- too, not just ents.FindByClass("stargate_*"). DHDs happen to share the
-- same "dhd_" prefix convention on both sides already (no bridge needed for
-- the wildcard case there), so only the exact pairs matter for them.
--
-- Not every class has a counterpart and that's fine - a class only on one
-- side (EAP's sg_alteran, CAP's stargate_asuran, CAP's many DHD/ramp/turret
-- variants EAP doesn't have, EAP's many ship variants CAP doesn't have) is
-- simply not bridged, which is the correct behavior: there's nothing on the
-- other side to find.

local CAP_TO_EAP = {
	-- Stargates
	["stargate_sg1"]       = "sg_sg1",
	["stargate_atlantis"]  = "sg_atlantis",
	["stargate_infinity"]  = "sg_infinity",
	["stargate_movie"]     = "sg_movie",
	["stargate_orlin"]     = "sg_orlin",
	["stargate_supergate"] = "sg_supergate",
	["stargate_tollan"]    = "sg_tollan",
	["stargate_universe"]  = "sg_universe",
	-- DHDs
	["dhd_sg1"]       = "dhd_milk",
	["dhd_atlantis"]  = "dhd_atl",
	["dhd_universe"]  = "dhd_uni",
	["dhd_concept"]   = "dhd_con",
	["dhd_city"]      = "dhd_atl_city",
	["dhd_infinity"]  = "dhd_inf",
	-- Rings
	["ring_base_ancient"] = "rg_base_ancient",
	["ring_base_goauld"]  = "rg_base_goauld",
	["ring_base_ori"]     = "rg_base_ori",
	-- Ring panels
	["ring_panel_ancient"] = "rg_panel_ancient",
	["ring_panel_goauld"]  = "rg_panel_goauld",
	["ring_panel_ori"]     = "rg_panel_ori",
	-- Obelisks
	["ancient_obelisk"] = "obelisk_ancient",
	["sodan_obelisk"]   = "obelisk_sodan",
	-- Transporters
	["transporter"]                 = "asgard_transporter",
	["atlantis_transporter"]        = "atlantis_trans",       -- corrected: CAP's folder is "atlantis_transporter", EAP's is "atlantis_trans" (the earlier draft had this backwards)
	["atlantis_transporter_doors"]  = "atlantis_trans_doors", -- was missing from the earlier draft entirely
	-- Ships
	["sg_vehicle_daedalus"]    = "ship_daedalus",
	["sg_vehicle_dart"]        = "ship_dart",
	["sg_vehicle_f302"]        = "ship_f302",
	["sg_vehicle_glider"]      = "ship_glider",
	["sg_vehicle_gate_glider"] = "ship_gate_glider",
	["puddle_jumper"]          = "ship_puddle_jumper",
	["sg_vehicle_shuttle"]     = "ship_shuttle",
	["sg_vehicle_teltac"]      = "ship_teltak", -- note the spelling difference between the two addons (teltac vs teltak) - intentional, both are correct for their own addon
}

local EAP_TO_CAP = {};
for capClass, eapClass in pairs(CAP_TO_EAP) do
	EAP_TO_CAP[eapClass] = capClass;
end

EAP.Compat.CapToEap = CAP_TO_EAP;
EAP.Compat.EapToCap = EAP_TO_CAP;

-- Prefix rule for stargates: lets ents.FindByClass("stargate_*") and
-- ents.FindByClass("sg_*") find each other's gates even for a gate type
-- that isn't explicitly listed above (future-proofing against either
-- addon adding a new gate type later, and already covers CAP's
-- "stargate_asuran" and EAP's "sg_alteran" for generic "any gate" searches
-- even though they have no direct counterpart).
local GATE_PREFIX_PAIR = {
	["stargate_"] = "sg_",
	["sg_"]       = "stargate_",
};

-- ===========================================================================
-- 2. ents.FindByClass bridge
-- ===========================================================================
-- Only installed, and only does anything, once CAP is actually detected.
-- When CAP isn't installed, ents.FindByClass is left completely untouched.

function EAP.Compat.InstallFindByClassBridge()
	if (EAP.Compat.FindByClassBridgeInstalled) then return end
	EAP.Compat.FindByClassBridgeInstalled = true;

	local RealFindByClass = ents.FindByClass;

	ents.FindByClass = function(classname, ...)
		local results = RealFindByClass(classname, ...);

		if (not Lib.IsCapDetected or type(classname) ~= "string") then
			return results;
		end

		-- Wildcard gate search: "sg_*" or "stargate_*"
		local prefix = classname:match("^(sg_)%*$") or classname:match("^(stargate_)%*$");
		if (prefix) then
			local otherPrefix = GATE_PREFIX_PAIR[prefix];
			if (otherPrefix) then
				local extra = RealFindByClass(otherPrefix .. "*", ...);
				if (extra and #extra > 0) then
					local merged = {};
					for _, v in ipairs(results) do merged[#merged + 1] = v; end
					for _, v in ipairs(extra) do merged[#merged + 1] = v; end
					return merged;
				end
			end
			return results;
		end

		-- Exact class search for anything in our two-way map
		local mapped = CAP_TO_EAP[classname] or EAP_TO_CAP[classname];
		if (mapped) then
			local extra = RealFindByClass(mapped, ...);
			if (extra and #extra > 0) then
				local merged = {};
				for _, v in ipairs(results) do merged[#merged + 1] = v; end
				for _, v in ipairs(extra) do merged[#merged + 1] = v; end
				return merged;
			end
		end

		return results;
	end
end

-- Install immediately if CAP is already known to be present (shared/init.lua
-- runs EAP.IsCapDetected() on PlayerInitialSpawn / at startup; this file is
-- loaded after that detection in eap_include.lua, see below), and again on
-- InitPostEntity as a safety net in case detection resolves slightly later
-- than this file loading.
if (Lib.IsCapDetected) then
	EAP.Compat.InstallFindByClassBridge();
end

-- ===========================================================================
-- 3. Client-side ENT:GetAllGates() fix
-- ===========================================================================
-- The client copy of GetAllGates() (sg_base / stargate_base cl_init.lua) is
-- used to decide which DHD / ramp belongs to which gate. Like the server one
-- (see server/init.lua), it buckets supergates with a class-literal compare
-- that doesn't recognise the other addon's supergate class. Reimplemented here
-- with the addon-agnostic .IsSupergate flag. ents.FindByClass("sg_*") is
-- already bridged above, so it returns both addons' gates.

function EAP.Compat.PatchClientGetAllGates()
	if (not CLIENT) then return end
	local eapStored = scripted_ents.GetStored("sg_base");
	local capStored = scripted_ents.GetStored("stargate_base");
	if (not eapStored or not eapStored.t or not capStored or not capStored.t) then
		MsgN("[EAP Compat] WARNING: couldn't find 'sg_base' and/or 'stargate_base' to fix the client GetAllGates() - were they really registered yet?");
		return;
	end
	if (eapStored.t.EAPCompatClientGetAllGatesPatched) then return end

	local function FixedGetAllGates(self, closed)
		local sg = {};
		local selfIsSuper = self.Entity.IsSupergate or false;
		for _, v in pairs(ents.FindByClass("sg_*")) do
			if (v.IsStargate and not (closed and (v.IsOpen or v.Dialling))) then
				if ((v.IsSupergate or false) == selfIsSuper) then
					table.insert(sg, v);
				end
			end
		end
		return sg;
	end

	eapStored.t.GetAllGates = FixedGetAllGates;
	capStored.t.GetAllGates = FixedGetAllGates;
	eapStored.t.EAPCompatClientGetAllGatesPatched = true;
	capStored.t.EAPCompatClientGetAllGatesPatched = true;
end

-- ===========================================================================
-- 4. Client-side system type receiver ("stargate_systemtype")
-- ===========================================================================
-- Both addons' servers send the same "stargate_systemtype" net message (1 bit,
-- Group/Galaxy system) and both clients register a receiver for it - but a
-- net message has a single receiver, so whichever addon loaded last would
-- silently stop the other one from ever seeing a system switch. One receiver
-- reading the bit once and updating both addons' variable replaces them.

function EAP.Compat.PatchClientSystemTypeReceiver()
	if (not CLIENT) then return end
	net.Receive("stargate_systemtype", function(len)
		local groupsystem = net.ReadBit();
		Lib.GroupSystem = groupsystem;
		if (StarGate) then StarGate.GroupSystem = groupsystem; end
	end);
end

hook.Add("InitPostEntity", "EAPCompat_InstallFindByClassBridge", function()
	if (Lib.IsCapDetected) then
		EAP.Compat.InstallFindByClassBridge();
		EAP.Compat.PatchClientGetAllGates();
		EAP.Compat.PatchClientSystemTypeReceiver();
	end
end);
