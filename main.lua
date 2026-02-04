-- bms-colorizer-2
-- Colorizes human-controlled BMS flights using Tacview telemetry.
-- Human detection: objects with non-empty "Pilot" text property.
-- Flight grouping: "CallSign" format <prefix><flightDigit><shipDigit> (e.g. Viper14, Dog11).

require("lua-strict")

local function requireTacview()
	-- Prefer the newest API available, fallback to older versions.
	-- If your Tacview ships a newer module than this list, add it at the top.
	local candidates =
	{
		"Tacview210", "Tacview209", "Tacview208", "Tacview207", "Tacview206", "Tacview205",
		"Tacview204", "Tacview203", "Tacview202", "Tacview201", "Tacview200",
		"Tacview199", "Tacview198", "Tacview197", "Tacview196", "Tacview195", "Tacview194",
		"Tacview193", "Tacview192", "Tacview191", "Tacview190", "Tacview189", "Tacview188",
		"Tacview187",
	}

	for _, apiName in ipairs(candidates) do
		local ok, api = pcall(require, apiName)
		if ok and api then
			return api, apiName
		end
	end

	error("bms-colorizer-2: Unable to load Tacview Lua API. Tried: "..table.concat(candidates, ", "))
end

local Tacview, TacviewApiName = requireTacview()
local telemetry = Tacview.Telemetry

local ADDON_TITLE = "BMS Colorizer 2"
local ADDON_VERSION = "0.2.0"
local ADDON_AUTHOR = "Van, BuzyBee, BS1 (reworked)"

local SETTINGS =
{
	AUTO_ASSIGN_ON_LOAD = "AutoAssignOnLoad",
	SHOW_LEGEND = "ShowLegend",
	FIXED_WING_ONLY = "FixedWingOnly",
	COLORIZE_MISSILES = "ColorizeMissiles",
	RENAME_MISSILES = "RenameMissiles",
}

-- Palette of color IDs/names to apply per-flight.
-- These must exist in Tacview's Data-ObjectsColors.xml (or be true Tacview built-in names).
-- When we run out of entries, we cycle back to the beginning.
local builtInFlightColors =
{
	"P1",
	"P2",
	"P3",
	"P4",
	"P5",
	"P6",
	"P7",
	"P8",
	"P9",
	"P10",
}

-- Temporary model-matching fixups for BMS exports.
-- Tacview's model database often keys off the "Name" property; BMS sometimes provides shorter names.
local modelNameFixups =
{
	["F-15C"] = "F-15C Eagle",
}

local state =
{
	menuRoot = nil,
	menuAutoAssign = nil,
	menuShowLegend = nil,
	menuFixedWingOnly = nil,
	menuColorizeMissiles = nil,
	menuRenameMissiles = nil,

	lastDataTimeRangeKey = nil,
	lastColorizedDataTimeRangeKey = nil,

	isApplying = false,

	legendRenderStateHandle = nil,
	legendBackgroundRenderStateHandle = nil,
	legendBackgroundVertexArrayHandle = nil,
	legendBackgroundWidth = nil,
	legendBackgroundHeight = nil,
	legendSwatchVertexArrayHandle = nil,
	legendSwatchColorArgbById = nil,
	legendSwatchColorLoaded = false,
	legendSwatchRenderStateById = {},
	legendLines = {},
	legendSwatchIds = {},

	processingRenderStateHandle = nil,
	processingBackgroundRenderStateHandle = nil,
	processingBackgroundVertexArrayHandle = nil,
	processingBackgroundWidth = nil,
	processingBackgroundHeight = nil,

	pendingApply = false,
	startApplyNextUpdate = false,
	applyCoroutine = nil,
	applyYield = nil,
}

local function logInfo(...)
	if Tacview.Log and Tacview.Log.Info then
		Tacview.Log.Info(ADDON_TITLE..": ", ...)
		return
	end
	print(ADDON_TITLE..": ", ...)
end

local function logWarning(...)
	if Tacview.Log and Tacview.Log.Warning then
		Tacview.Log.Warning(ADDON_TITLE..": ", ...)
		return
	end
	logInfo(...)
end

local function getAddonSettingBoolean(settingName, defaultValue)
	local s = Tacview.AddOns.Current.Settings
	if s and s.GetBoolean then
		return s.GetBoolean(settingName, defaultValue)
	end
	return defaultValue
end

local function setAddonSettingBoolean(settingName, newValue)
	local s = Tacview.AddOns.Current.Settings
	if s and s.SetBoolean then
		s.SetBoolean(settingName, newValue)
	end
end

local function toggleOption(menuId, settingName, defaultValue)
	local newValue = not getAddonSettingBoolean(settingName, defaultValue)
	setAddonSettingBoolean(settingName, newValue)
	Tacview.UI.Menus.SetOption(menuId, newValue)
	Tacview.UI.Update()
end

local function getDataTimeRangeKey()
	if not telemetry.GetDataTimeRange then
		return nil
	end

	local beginTime, endTime = telemetry.GetDataTimeRange()
	if not beginTime or not endTime then
		return nil
	end

	return tostring(beginTime).."|"..tostring(endTime)
end

local function isBMSFlight()
	-- Robust to no telemetry loaded yet.
	if telemetry.IsLikeEmpty and telemetry.IsLikeEmpty() then
		return false
	end

	if not telemetry.GetGlobalTextPropertyIndex then
		return false
	end

	local function getGlobalText(propertyName)
		local propertyIndex = telemetry.GetGlobalTextPropertyIndex(propertyName, false)
		if propertyIndex == telemetry.InvalidPropertyIndex then
			return ""
		end
		local value = telemetry.GetTextSample(0, telemetry.BeginningOfTime, propertyIndex)
		if type(value) ~= "string" then
			return ""
		end
		return value
	end

	local dataRecorder = getGlobalText("DataRecorder")
	local dataSource = getGlobalText("DataSource")
	local haystack = dataRecorder.." "..dataSource

	if string.find(haystack, "Falcon BMS", 1, true) or string.find(haystack, "Falcon 4.0", 1, true) then
		return true
	end

	return false
end

local function parseBmsCallSign(callSign)
	-- Expected BMS format: <prefix><flightDigit><shipDigit>
	-- Examples: Viper14, Dog11, Nightwing53
	if type(callSign) ~= "string" then
		return nil
	end

	callSign = string.gsub(callSign, "%s+", "")
	if callSign == "" then
		return nil
	end

	local prefix, flightDigit, shipDigit = string.match(callSign, "^(.-)(%d)(%d)$")
	if not prefix or prefix == "" then
		return nil
	end

	local shipIndex = tonumber(shipDigit)
	if not shipIndex or shipIndex < 1 or shipIndex > 4 then
		return nil
	end

	return prefix..flightDigit, shipIndex
end

local function getTextSample(objectHandle, absoluteTime, propertyIndex)
	local value = telemetry.GetTextSample(objectHandle, absoluteTime, propertyIndex)
	if type(value) ~= "string" then
		return ""
	end
	return value
end

local function getObjectLifetimeTimes(objectHandle)
	local t1, t2 = telemetry.GetLifeTime(objectHandle)
	if t2 ~= nil then
		return t1, t2
	end
	return nil, t1
end

local function scanHumanObjects(propertyIndexByName)
	local humanObjects = {}

	local objectCount = telemetry.GetObjectCount()
	if not objectCount or objectCount <= 0 then
		return humanObjects
	end

	local fixedWingOnly = getAddonSettingBoolean(SETTINGS.FIXED_WING_ONLY, true)

	local step = 0
	for objectIndex = 0, objectCount - 1 do
		local objectHandle = telemetry.GetObjectHandleByIndex(objectIndex)
		if objectHandle then
			step = step + 1
			if step % 300 == 0 and state.applyYield then
				state.applyYield()
			end
			local lifeTimeBegin, lifeTimeEnd = getObjectLifetimeTimes(objectHandle)
			local writeTime = lifeTimeEnd or lifeTimeBegin
			if writeTime then
				-- Use a time after the object lifetime to fetch the "last known" values.
				-- This matches older working add-ons which used lifeTime+1 for sampling.
				local readTime = writeTime + 1

				local pilot = getTextSample(objectHandle, readTime, propertyIndexByName.pilot)
				if pilot ~= "" then
					local include = true
					if fixedWingOnly then
						local typeName = getTextSample(objectHandle, readTime, propertyIndexByName.type)
						include = (typeName == "Air+FixedWing")
					end

					if include then
						local callSign = getTextSample(objectHandle, readTime, propertyIndexByName.callSign)
						if callSign == "" and lifeTimeBegin then
							callSign = getTextSample(objectHandle, lifeTimeBegin, propertyIndexByName.callSign)
						end

						local flightKey, shipIndex = parseBmsCallSign(callSign)

						-- Fallback: some recorders may not export CallSign but may export it in Name.
						if not flightKey and propertyIndexByName.name then
							local name = getTextSample(objectHandle, readTime, propertyIndexByName.name)
							if name == "" and lifeTimeBegin then
								name = getTextSample(objectHandle, lifeTimeBegin, propertyIndexByName.name)
							end
							flightKey, shipIndex = parseBmsCallSign(name)
						end

						if flightKey and shipIndex then
							table.insert(humanObjects,
								{
									handle = objectHandle,
									lifeTimeBegin = lifeTimeBegin,
									writeTime = writeTime,
									pilot = pilot,
									callSign = callSign,
									flightKey = flightKey,
									shipIndex = shipIndex,
								})
						end
					end
				end
			end
		end
	end

	return humanObjects
end

local function fixModelNames(propertyIndexByName)
	local namePropertyIndex = propertyIndexByName.name
	if not namePropertyIndex then
		return 0
	end

	local objectCount = telemetry.GetObjectCount()
	if not objectCount or objectCount <= 0 then
		return 0
	end

	local fixedWingOnly = getAddonSettingBoolean(SETTINGS.FIXED_WING_ONLY, true)
	local fixed = 0

	local step = 0
	for objectIndex = 0, objectCount - 1 do
		local objectHandle = telemetry.GetObjectHandleByIndex(objectIndex)
		if objectHandle then
			step = step + 1
			if step % 300 == 0 and state.applyYield then
				state.applyYield()
			end
			local lifeTimeBegin, lifeTimeEnd = getObjectLifetimeTimes(objectHandle)
			local writeTime = lifeTimeEnd or lifeTimeBegin
			if writeTime then
				local readTime = writeTime + 1

				if fixedWingOnly then
					local typeName = getTextSample(objectHandle, readTime, propertyIndexByName.type)
					if typeName ~= "Air+FixedWing" then
						goto continue_object
					end
				end

				local currentName = getTextSample(objectHandle, readTime, namePropertyIndex)
				if currentName ~= "" then
					local desiredName = modelNameFixups[currentName]
					if desiredName and desiredName ~= currentName then
						-- Apply at beginning so the model can be resolved early, and at end to override recorder updates.
						if lifeTimeBegin then
							telemetry.SetTextSample(objectHandle, lifeTimeBegin, namePropertyIndex, desiredName)
						end
						telemetry.SetTextSample(objectHandle, writeTime, namePropertyIndex, desiredName)
						fixed = fixed + 1
					end
				end
			end
		end

		::continue_object::
	end

	return fixed
end

local function assignMissileCallSigns(propertyIndexByName)
	local namePropertyIndex = propertyIndexByName.name
	local callSignPropertyIndex = propertyIndexByName.callSign
	local typePropertyIndex = propertyIndexByName.type
	if not namePropertyIndex or not callSignPropertyIndex or not typePropertyIndex then
		return 0
	end

	local objectCount = telemetry.GetObjectCount()
	if not objectCount or objectCount <= 0 then
		return 0
	end

	local updated = 0
	local total = 0
	local missileType = 0
	local missingName = 0
	local alreadyHasCallSign = 0
	local sample = {}

	local function isMissileObject(objectHandle, readTime)
		if telemetry.GetCurrentTags and telemetry.AnyGivenTagActive and telemetry.Tags and telemetry.Tags.Missile then
			local tags = telemetry.GetCurrentTags(objectHandle)
			if tags and telemetry.AnyGivenTagActive(tags, telemetry.Tags.Missile) then
				return true
			end
		end
		local typeName = getTextSample(objectHandle, readTime, typePropertyIndex)
		return typeName ~= "" and (string.find(typeName, "Weapon+Missile", 1, true) or string.find(typeName, "Missile", 1, true))
	end

	local step = 0
	for objectIndex = 0, objectCount - 1 do
		local objectHandle = telemetry.GetObjectHandleByIndex(objectIndex)
		if objectHandle then
			step = step + 1
			if step % 300 == 0 and state.applyYield then
				state.applyYield()
			end
			total = total + 1
			local lifeTimeBegin, lifeTimeEnd = getObjectLifetimeTimes(objectHandle)
			local writeTime = lifeTimeEnd or lifeTimeBegin
			if writeTime then
				local readTime = writeTime + 1
				if isMissileObject(objectHandle, readTime) then
					missileType = missileType + 1
					local existingCallSign = getTextSample(objectHandle, readTime, callSignPropertyIndex)
					if existingCallSign == "" then
						local nameValue = getTextSample(objectHandle, readTime, namePropertyIndex)
						if nameValue == "" and lifeTimeBegin then
							nameValue = getTextSample(objectHandle, lifeTimeBegin, namePropertyIndex)
						end
						if nameValue ~= "" then
							if lifeTimeBegin then
								telemetry.SetTextSample(objectHandle, lifeTimeBegin, callSignPropertyIndex, nameValue)
							end
							telemetry.SetTextSample(objectHandle, writeTime, callSignPropertyIndex, nameValue)
							updated = updated + 1
							if #sample < 3 then
								table.insert(sample, nameValue)
							end
						end
						if nameValue == "" then
							missingName = missingName + 1
						end
					else
						alreadyHasCallSign = alreadyHasCallSign + 1
					end
				end
			end
		end
	end

	logInfo(("Missile call sign scan: total=%d missileType=%d updated=%d missingName=%d alreadyHasCallSign=%d"):format(total, missileType, updated, missingName, alreadyHasCallSign))
	if #sample > 0 then
		logInfo("Missile call sign samples (from Name): ", table.concat(sample, ", "))
	end
	return updated
end

local function assignMissileColors(propertyIndexByName, callSignToColor)
	local colorPropertyIndex = propertyIndexByName.color
	local callSignPropertyIndex = propertyIndexByName.callSign
	local typePropertyIndex = propertyIndexByName.type
	if not colorPropertyIndex or not callSignPropertyIndex or not typePropertyIndex then
		return 0
	end
	if not callSignToColor then
		return 0
	end
	if not telemetry.GetCurrentParentHandle then
		logWarning("Missile color scan: Telemetry.GetCurrentParentHandle not available.")
		return 0
	end

	local objectCount = telemetry.GetObjectCount()
	if not objectCount or objectCount <= 0 then
		return 0
	end

	local updated = 0
	local total = 0
	local missileType = 0
	local missingParent = 0
	local missingParentCallSign = 0
	local missingParentColor = 0
	local sample = {}

	local function isMissileObject(objectHandle, readTime)
		if telemetry.GetCurrentTags and telemetry.AnyGivenTagActive and telemetry.Tags and telemetry.Tags.Missile then
			local tags = telemetry.GetCurrentTags(objectHandle)
			if tags and telemetry.AnyGivenTagActive(tags, telemetry.Tags.Missile) then
				return true
			end
		end
		local typeName = getTextSample(objectHandle, readTime, typePropertyIndex)
		return typeName ~= "" and (string.find(typeName, "Weapon+Missile", 1, true) or string.find(typeName, "Missile", 1, true))
	end

	local step = 0
	for objectIndex = 0, objectCount - 1 do
		local objectHandle = telemetry.GetObjectHandleByIndex(objectIndex)
		if objectHandle then
			step = step + 1
			if step % 300 == 0 and state.applyYield then
				state.applyYield()
			end
			total = total + 1
			local lifeTimeBegin, lifeTimeEnd = getObjectLifetimeTimes(objectHandle)
			local writeTime = lifeTimeEnd or lifeTimeBegin
			if writeTime then
				local readTime = writeTime + 1
				if isMissileObject(objectHandle, readTime) then
					missileType = missileType + 1
					local parentHandle = telemetry.GetCurrentParentHandle(objectHandle)
					if parentHandle then
						local parentCallSign = getTextSample(parentHandle, readTime, callSignPropertyIndex)
						if parentCallSign == "" and lifeTimeBegin then
							parentCallSign = getTextSample(parentHandle, lifeTimeBegin, callSignPropertyIndex)
						end
						local colorValue = parentCallSign ~= "" and callSignToColor[parentCallSign] or nil
						if colorValue then
						if lifeTimeBegin then
							telemetry.SetTextSample(objectHandle, lifeTimeBegin, colorPropertyIndex, colorValue)
						end
						telemetry.SetTextSample(objectHandle, writeTime, colorPropertyIndex, colorValue)
						updated = updated + 1
						if #sample < 3 then
								table.insert(sample, parentCallSign)
						end
						else
							if parentCallSign == "" then
								missingParentCallSign = missingParentCallSign + 1
							else
								missingParentColor = missingParentColor + 1
							end
						end
					else
						missingParent = missingParent + 1
					end
				end
			end
		end
	end

		logInfo(("Missile color scan: total=%d missileType=%d updated=%d missingParent=%d missingParentCallSign=%d missingParentColor=%d"):format(total, missileType, updated, missingParent, missingParentCallSign, missingParentColor))
	if #sample > 0 then
			logInfo("Missile color samples (parent call sign matched): ", table.concat(sample, ", "))
	end
	return updated
end

local function buildFlightIndexByKey(humanObjects)
	local seen = {}
	local keys = {}

	for _, obj in ipairs(humanObjects) do
		if obj.flightKey and not seen[obj.flightKey] then
			seen[obj.flightKey] = true
			table.insert(keys, obj.flightKey)
		end
	end

	table.sort(keys)

	local indexByKey = {}
	for i, k in ipairs(keys) do
		indexByKey[k] = i
	end

	return keys, indexByKey
end

local function getFlightColorValue(flightIndex)
	local n = #builtInFlightColors
	if n <= 0 then
		return nil
	end

	local i = ((flightIndex - 1) % n) + 1
	return builtInFlightColors[i]
end

local function tryLoadLegendSwatchColorsFromTacviewXml()
	if state.legendSwatchColorLoaded then
		return
	end
	state.legendSwatchColorLoaded = true

	local function getAddonDirectory()
		if debug and debug.getinfo then
			local info = debug.getinfo(1, "S")
			local source = info and info.source or ""
			if source:sub(1, 1) == "@" then
				source = source:sub(2)
			end
			source = source:gsub("/", "\\")
			local dir = source:match("^(.*)\\[^\\]+$")
			if dir and dir ~= "" then
				return dir
			end
		end
		return "."
	end

	local wanted = {}
	for _, id in ipairs(builtInFlightColors) do
		wanted[id] = true
	end

	local addonDir = getAddonDirectory()
	local candidates =
	{
		addonDir .. "\\Data-ObjectsColors.xml"
	}

	local function parseHexRgbToAbgr(hex)
		if type(hex) ~= "string" then
			return nil
		end
		hex = hex:gsub("#", ""):gsub("%s+", "")
		if #hex ~= 6 then
			return nil
		end
		local r = tonumber(hex:sub(1, 2), 16)
		local g = tonumber(hex:sub(3, 4), 16)
		local b = tonumber(hex:sub(5, 6), 16)
		if not r or not g or not b then
			return nil
		end
		return 0xFF000000 + (b * 0x10000) + (g * 0x100) + r
	end

	local function readFile(path)
		local f = io.open(path, "r")
		if not f then
			return nil
		end
		local content = f:read("*a")
		f:close()
		return content
	end

	local colors = {}
	local foundAny = false

	for _, path in ipairs(candidates) do
		local content = readFile(path)
		if content then
			for _, colorId in ipairs(builtInFlightColors) do
				if not colors[colorId] then
					-- Parse a specific block like:
					-- <Color ID="P1"> ... <Side>#RRGGBB</Side> ... </Color>
					local blockPattern = '<Color%s+ID="' .. colorId .. '">%s*(.-)%s*</Color>'
					local block = content:match(blockPattern)
					local sideHex = nil
					if block then
						sideHex = block:match('<Side>%s*(#[0-9a-fA-F]+)%s*</Side>')
					end
					local sideArgb = parseHexRgbToAbgr(sideHex)
					if sideArgb then
						colors[colorId] = sideArgb
						foundAny = true
					end
				end
			end
		end
	end

	state.legendSwatchColorArgbById = colors
	if not foundAny then
		-- Still set an empty table so we don't try again every frame.
		state.legendSwatchColorArgbById = {}
	end
end

local function buildRepresentativeCallSignByFlightKey(humanObjects)
	-- Prefer ship #1 callsign for each flight, otherwise smallest available ship index.
	local best = {}

	for _, obj in ipairs(humanObjects) do
		if obj.flightKey and obj.shipIndex and obj.callSign and obj.callSign ~= "" then
			local existing = best[obj.flightKey]
			if not existing then
				best[obj.flightKey] = { shipIndex = obj.shipIndex, callSign = obj.callSign }
			else
				if obj.shipIndex == 1 and existing.shipIndex ~= 1 then
					best[obj.flightKey] = { shipIndex = obj.shipIndex, callSign = obj.callSign }
				elseif existing.shipIndex ~= 1 and obj.shipIndex < existing.shipIndex then
					best[obj.flightKey] = { shipIndex = obj.shipIndex, callSign = obj.callSign }
				end
			end
		end
	end

	local rep = {}
	for flightKey, data in pairs(best) do
		rep[flightKey] = data.callSign
	end
	return rep
end

local function rebuildLegendLines(flightKeys, indexByKey, representativeCallSignByFlightKey)
	local lines = {}
	local swatchIds = {}

	local maxFlights = math.min(#flightKeys, 10)

	for i = 1, maxFlights do
		local fk = flightKeys[i]
		local flightIndex = indexByKey[fk]
		local leadCallSign = (representativeCallSignByFlightKey and representativeCallSignByFlightKey[fk]) or (fk .. "1")
		local colorId = getFlightColorValue(flightIndex) or nil

		table.insert(lines, leadCallSign)
		table.insert(swatchIds, colorId)
	end

	return lines, swatchIds
end

local function requestAssignColors()
	if state.isApplying or state.pendingApply or state.startApplyNextUpdate then
		return
	end
	state.pendingApply = true
	Tacview.UI.Update()
end

local function assignColors()
	state.applyYield = function()
		if coroutine.running() then
			coroutine.yield()
		end
	end

	tryLoadLegendSwatchColorsFromTacviewXml()

	local function colorValueToHex(abgr)
		if not abgr then
			return nil
		end
		local b = math.floor(abgr / 0x10000) % 0x100
		local g = math.floor(abgr / 0x100) % 0x100
		local r = abgr % 0x100
		return string.format("#%02X%02X%02X", r, g, b)
	end

	if telemetry.IsLikeEmpty and telemetry.IsLikeEmpty() then
		logInfo("No telemetry loaded.")
		return
	end

	if not isBMSFlight() then
		logInfo("Not a BMS ACMI (or not loaded yet).")
		return
	end

	local colorPropertyIndex = telemetry.GetObjectsTextPropertyIndex("Color", false)
	if colorPropertyIndex == telemetry.InvalidPropertyIndex then
		logWarning("Could not find telemetry text property: Color")
		return
	end

	local pilotPropertyIndex = telemetry.GetObjectsTextPropertyIndex("Pilot", false)
	if pilotPropertyIndex == telemetry.InvalidPropertyIndex then
		logWarning("Could not find telemetry text property: Pilot")
		return
	end

	local callSignPropertyIndex = telemetry.GetObjectsTextPropertyIndex("CallSign", false)
	if callSignPropertyIndex == telemetry.InvalidPropertyIndex then
		logWarning("Could not find telemetry text property: CallSign")
		return
	end

	local typePropertyIndex = telemetry.GetObjectsTextPropertyIndex("Type", false)
	if typePropertyIndex == telemetry.InvalidPropertyIndex then
		logWarning("Could not find telemetry text property: Type")
		return
	end

	local namePropertyIndex = telemetry.GetObjectsTextPropertyIndex("Name", false)
	if namePropertyIndex == telemetry.InvalidPropertyIndex then
		namePropertyIndex = nil
	end

	local propertyIndexByName =
	{
		color = colorPropertyIndex,
		pilot = pilotPropertyIndex,
		callSign = callSignPropertyIndex,
		type = typePropertyIndex,
		name = namePropertyIndex,
	}

	local fixedNames = fixModelNames(propertyIndexByName)
	local missileCallSigns = 0
	if getAddonSettingBoolean(SETTINGS.RENAME_MISSILES, true) then
		missileCallSigns = assignMissileCallSigns(propertyIndexByName)
	end

	local humanObjects = scanHumanObjects(propertyIndexByName)
	if #humanObjects == 0 then
		logInfo("No human-controlled aircraft found (objects with non-empty Pilot).")
		state.legendLines = {}
		state.legendSwatchIds = {}
		return
	end

	local flightKeys, indexByKey = buildFlightIndexByKey(humanObjects)
	local representativeCallSignByFlightKey = buildRepresentativeCallSignByFlightKey(humanObjects)

	local colored = 0
	local skipped = 0
	local callSignToColor = {}

	local step = 0
	for _, obj in ipairs(humanObjects) do
		step = step + 1
		if step % 300 == 0 and state.applyYield then
			state.applyYield()
		end
		local flightIndex = indexByKey[obj.flightKey]
		if flightIndex then
			local colorValue = getFlightColorValue(flightIndex)
			if colorValue then
				if obj.callSign and obj.callSign ~= "" then
					callSignToColor[obj.callSign] = colorValue
				end
				-- Apply at the beginning so it affects the whole track (Tacview samples are time-based).
				-- Also apply at the end to ensure our value wins if the recorder wrote one.
				local beginTime = obj.lifeTimeBegin or obj.writeTime
				if beginTime then
					telemetry.SetTextSample(obj.handle, beginTime, colorPropertyIndex, colorValue)
				end
				if obj.writeTime and obj.writeTime ~= beginTime then
					telemetry.SetTextSample(obj.handle, obj.writeTime, colorPropertyIndex, colorValue)
				end
				colored = colored + 1
			else
				skipped = skipped + 1
			end
		else
			skipped = skipped + 1
		end
	end

	local missileColors = 0
	if getAddonSettingBoolean(SETTINGS.COLORIZE_MISSILES, true) then
		missileColors = assignMissileColors(propertyIndexByName, callSignToColor)
	end

	state.legendLines, state.legendSwatchIds = rebuildLegendLines(flightKeys, indexByKey, representativeCallSignByFlightKey)
	state.lastColorizedDataTimeRangeKey = getDataTimeRangeKey()

	Tacview.UI.Update()
	if fixedNames > 0 then
		logInfo(("Fixed %d object name(s) for model matching."):format(fixedNames))
	end
	if missileCallSigns > 0 then
		logInfo(("Assigned call signs to %d missile(s)."):format(missileCallSigns))
	end
	if missileColors > 0 then
		logInfo(("Colored %d missile(s) to match parent call signs."):format(missileColors))
	end
	logInfo(("Colored %d aircraft across %d flight(s); skipped %d."):format(colored, #flightKeys, skipped))

	state.applyYield = nil
end

local function drawLegend()
	local showLegend = getAddonSettingBoolean(SETTINGS.SHOW_LEGEND, true)
	local processing = state.isApplying or state.pendingApply or state.startApplyNextUpdate
	if not showLegend and not processing then
		return
	end

	if not Tacview.UI or not Tacview.UI.Renderer then
		return
	end

	local renderer = Tacview.UI.Renderer
	if not renderer.Print or not renderer.CreateRenderState then
		return
	end

	if processing then
		if not state.processingRenderStateHandle then
			local blendMode = renderer.BlendMode and renderer.BlendMode.Additive or nil
			state.processingRenderStateHandle = renderer.CreateRenderState(
				{
					color = 0xffffffff,
					blendMode = blendMode,
				})
		end

		if not state.processingBackgroundRenderStateHandle then
			state.processingBackgroundRenderStateHandle = renderer.CreateRenderState({ color = 0x80000000 })
		end

		local w = renderer.GetWidth and renderer.GetWidth() or nil
		local h = renderer.GetHeight and renderer.GetHeight() or nil
		if w and h then
			local fontSize = 28
			local text = "Processing .acmi..."
			local padding = 14
			local textWidth = #text * 7 * (fontSize / 14)
			local backgroundWidth = math.floor(textWidth + padding * 2 + 0.5)
			local backgroundHeight = math.floor(fontSize + padding * 2 + 0.5)
			local textY = math.floor(h * 0.5 + 0.5)
			local backgroundTopY = textY + fontSize + padding

			if renderer.DrawUIVertexArray and renderer.CreateVertexArray and renderer.ReleaseVertexArray then
				if not state.processingBackgroundVertexArrayHandle
					or state.processingBackgroundWidth ~= backgroundWidth
					or state.processingBackgroundHeight ~= backgroundHeight then

					if state.processingBackgroundVertexArrayHandle then
						renderer.ReleaseVertexArray(state.processingBackgroundVertexArrayHandle)
						state.processingBackgroundVertexArrayHandle = nil
					end

					local vertexArray =
					{
						0, 0, 0,
						0, -backgroundHeight, 0,
						backgroundWidth, -backgroundHeight, 0,
						0, 0, 0,
						backgroundWidth, 0, 0,
						backgroundWidth, -backgroundHeight, 0,
						0, 0, 0,
					}

					state.processingBackgroundVertexArrayHandle = renderer.CreateVertexArray(vertexArray)
					state.processingBackgroundWidth = backgroundWidth
					state.processingBackgroundHeight = backgroundHeight
				end

				if state.processingBackgroundVertexArrayHandle then
					local backgroundTransform =
					{
						x = math.floor(w * 0.5 - backgroundWidth * 0.5 + 0.5),
						y = math.floor(backgroundTopY + 0.5),
						scale = 1,
					}
					renderer.DrawUIVertexArray(backgroundTransform, state.processingBackgroundRenderStateHandle, state.processingBackgroundVertexArrayHandle)
				end
			end

			local textTransform =
			{
				x = math.floor(w * 0.5 - textWidth * 0.5 + 0.5),
				y = textY,
				scale = fontSize,
			}
			renderer.Print(textTransform, state.processingRenderStateHandle, text)
		end
	end

	if not showLegend or not state.legendLines or #state.legendLines == 0 then
		return
	end

	if not state.legendRenderStateHandle then
		local blendMode = renderer.BlendMode and renderer.BlendMode.Additive or nil
		state.legendRenderStateHandle = renderer.CreateRenderState(
			{
				color = 0xffffffff,
				blendMode = blendMode,
			})
	end

	-- Tacview UI uses screen-space coordinates; see official add-ons like turn-rate.
	local function stripTextControls(s)
		return tostring(s):gsub(".", function(c)
			local b = string.byte(c)
			if b and b >= 1 and b <= 6 then
				return ""
			end
			return c
		end)
	end

	local legendX = 16
	-- Tacview UI origin is bottom-left (y increases upward).
	-- Anchor to bottom-left corner and compute top Y from line count.
	local legendBottomMargin = 16
	local fontSize = 14
	local padding = 10
	local lineHeight = fontSize + 2

	local maxLen = 0
	for _, line in ipairs(state.legendLines) do
		local visible = stripTextControls(line)
		if #visible > maxLen then
			maxLen = #visible
		end
	end

	local baseWidth = padding * 2 + maxLen * 7
	-- User preference: narrower legend background.
	local backgroundWidth = math.max(180, math.floor(baseWidth * 0.67 + 0.5))

	-- Extra top padding because text y is baseline-like in practice.
	-- The legend already includes one line per flight; avoid adding a full extra line of height.
	local lineCount = #state.legendLines
	local contentHeight = 0
	if lineCount > 0 then
		contentHeight = (lineCount - 1) * lineHeight + fontSize
	end
	local backgroundHeight = padding * 2 + contentHeight

	-- Background is drawn from its top edge downward; text is drawn from its top line downward.
	local backgroundTopY = legendBottomMargin + backgroundHeight
	local legendTopY = backgroundTopY - padding - fontSize

	if renderer.DrawUIVertexArray and renderer.CreateVertexArray and renderer.ReleaseVertexArray then
		if not state.legendBackgroundRenderStateHandle then
			state.legendBackgroundRenderStateHandle = renderer.CreateRenderState({ color = 0x80000000 })
		end

		if not state.legendBackgroundVertexArrayHandle
			or state.legendBackgroundWidth ~= backgroundWidth
			or state.legendBackgroundHeight ~= backgroundHeight then

			if state.legendBackgroundVertexArrayHandle then
				renderer.ReleaseVertexArray(state.legendBackgroundVertexArrayHandle)
				state.legendBackgroundVertexArrayHandle = nil
			end

			local vertexArray =
			{
				0, 0, 0,
				0, -backgroundHeight, 0,
				backgroundWidth, -backgroundHeight, 0,
				0, 0, 0,
				backgroundWidth, 0, 0,
				backgroundWidth, -backgroundHeight, 0,
				0, 0, 0,
			}

			state.legendBackgroundVertexArrayHandle = renderer.CreateVertexArray(vertexArray)
			state.legendBackgroundWidth = backgroundWidth
			state.legendBackgroundHeight = backgroundHeight
		end

		if state.legendBackgroundVertexArrayHandle then
			local backgroundTransform =
			{
				x = legendX - padding,
				y = backgroundTopY,
				scale = 1,
			}
			renderer.DrawUIVertexArray(backgroundTransform, state.legendBackgroundRenderStateHandle, state.legendBackgroundVertexArrayHandle)
		end
	end

	tryLoadLegendSwatchColorsFromTacviewXml()

	local swatchSize = fontSize - 2
	if swatchSize < 8 then
		swatchSize = 8
	end

	if not state.legendSwatchVertexArrayHandle and renderer.CreateVertexArray then
		local va =
		{
			0, 0, 0,
			0, -swatchSize, 0,
			swatchSize, -swatchSize, 0,
			0, 0, 0,
			swatchSize, 0, 0,
			swatchSize, -swatchSize, 0,
			0, 0, 0,
		}
		state.legendSwatchVertexArrayHandle = renderer.CreateVertexArray(va)
	end

	local function getSwatchRenderState(colorId)
		if not colorId or not state.legendSwatchColorArgbById then
			return nil
		end

		local existing = state.legendSwatchRenderStateById[colorId]
		if existing then
			return existing
		end

		local argb = state.legendSwatchColorArgbById[colorId]
		if not argb then
			return nil
		end

		local handle = renderer.CreateRenderState({ color = argb })
		state.legendSwatchRenderStateById[colorId] = handle
		return handle
	end

	for lineIndex, line in ipairs(state.legendLines) do
		-- Draw from top (line 1) down to bottom.
		local y = legendTopY - (lineIndex - 1) * lineHeight
		local swatchIndex = lineIndex
		local colorId = state.legendSwatchIds and state.legendSwatchIds[swatchIndex] or nil

		if state.legendSwatchVertexArrayHandle and renderer.DrawUIVertexArray then
			local swatchState = getSwatchRenderState(colorId)
			if swatchState then
				local swatchTopY = y + (fontSize + swatchSize) * 0.5
				local swatchTransform =
				{
					x = legendX,
					-- Match swatch to text glyph area (baseline at y; text extends upward).
					y = swatchTopY,
					scale = 1,
				}
				renderer.DrawUIVertexArray(swatchTransform, swatchState, state.legendSwatchVertexArrayHandle)
			end
		end

		local textTransform =
		{
			x = legendX + swatchSize + 8,
			y = y,
			scale = fontSize,
		}
		renderer.Print(textTransform, state.legendRenderStateHandle, line)
	end
end

local function onUpdate()
	if state.pendingApply then
		state.pendingApply = false
		state.isApplying = true
		state.startApplyNextUpdate = true
		Tacview.UI.Update()
		return
	end

	if state.startApplyNextUpdate then
		state.startApplyNextUpdate = false
		state.applyCoroutine = coroutine.create(assignColors)
		Tacview.UI.Update()
		return
	end

	if state.applyCoroutine then
		if type(state.applyCoroutine) ~= "thread" then
			logWarning("Apply coroutine invalid; resetting.")
			state.applyCoroutine = nil
			state.applyYield = nil
			state.isApplying = false
			Tacview.UI.Update()
			return
		end
		local ok, err = coroutine.resume(state.applyCoroutine)
		if not ok then
			logWarning("Apply failed: ", err)
			state.applyCoroutine = nil
			state.applyYield = nil
			state.isApplying = false
			Tacview.UI.Update()
			return
		end
		if type(state.applyCoroutine) == "thread" and coroutine.status(state.applyCoroutine) == "dead" then
			state.applyCoroutine = nil
			state.applyYield = nil
			state.isApplying = false
			Tacview.UI.Update()
		end
		return
	end

	local currentKey = getDataTimeRangeKey()
	if not currentKey then
		return
	end

	if state.lastDataTimeRangeKey ~= currentKey then
		state.lastDataTimeRangeKey = currentKey
		state.lastColorizedDataTimeRangeKey = nil
	end

	if not getAddonSettingBoolean(SETTINGS.AUTO_ASSIGN_ON_LOAD, true) then
		return
	end

	if state.lastColorizedDataTimeRangeKey == currentKey then
		return
	end

	if not isBMSFlight() then
		return
	end

	requestAssignColors()
end

local function registerEventListener(event, callback)
	if not event then
		return false
	end

	if event.RegisterListener then
		event.RegisterListener(callback)
		return true
	end

	if event.AddListener then
		event.AddListener(callback)
		return true
	end

	return false
end

local function Initialize()
	Tacview.AddOns.Current.SetTitle(ADDON_TITLE)
	Tacview.AddOns.Current.SetVersion(ADDON_VERSION)
	Tacview.AddOns.Current.SetAuthor(ADDON_AUTHOR)
	Tacview.AddOns.Current.SetNotes("Colorize human pilots by flight (CallSign) when Pilot name is present")

	state.menuRoot = Tacview.UI.Menus.AddMenu(nil, ADDON_TITLE)
	Tacview.UI.Menus.AddCommand(state.menuRoot, "Assign Colors Now", requestAssignColors)
	Tacview.UI.Menus.AddSeparator(state.menuRoot)

	state.menuAutoAssign = Tacview.UI.Menus.AddOption(
		state.menuRoot,
		"Auto-Assign On Load",
		getAddonSettingBoolean(SETTINGS.AUTO_ASSIGN_ON_LOAD, true),
		function()
			toggleOption(state.menuAutoAssign, SETTINGS.AUTO_ASSIGN_ON_LOAD, true)
		end)

	state.menuShowLegend = Tacview.UI.Menus.AddOption(
		state.menuRoot,
		"Show Legend Overlay",
		getAddonSettingBoolean(SETTINGS.SHOW_LEGEND, true),
		function()
			toggleOption(state.menuShowLegend, SETTINGS.SHOW_LEGEND, true)
		end)

	state.menuFixedWingOnly = Tacview.UI.Menus.AddOption(
		state.menuRoot,
		"Fixed-Wing Only (recommended)",
		getAddonSettingBoolean(SETTINGS.FIXED_WING_ONLY, true),
		function()
			toggleOption(state.menuFixedWingOnly, SETTINGS.FIXED_WING_ONLY, true)
		end)

	state.menuColorizeMissiles = Tacview.UI.Menus.AddOption(
		state.menuRoot,
		"Colorize Missiles",
		getAddonSettingBoolean(SETTINGS.COLORIZE_MISSILES, true),
		function()
			toggleOption(state.menuColorizeMissiles, SETTINGS.COLORIZE_MISSILES, true)
		end)

	state.menuRenameMissiles = Tacview.UI.Menus.AddOption(
		state.menuRoot,
		"Rename Missiles",
		getAddonSettingBoolean(SETTINGS.RENAME_MISSILES, true),
		function()
			toggleOption(state.menuRenameMissiles, SETTINGS.RENAME_MISSILES, true)
		end)

	Tacview.UI.Menus.AddSeparator(state.menuRoot)
	Tacview.UI.Menus.AddCommand(state.menuRoot, "About / Help", function()
		logInfo("Humans are detected by non-empty 'Pilot'. Flights are grouped by CallSign XX where last two digits are flight/ship.")
		logInfo("Colors come from builtInFlightColors in this add-on; they must exist in Tacview's Data-ObjectsColors.xml (unless using true built-in names).")
	end)

	Tacview.UI.Menus.AddCommand(state.menuRoot, "Debug: Dump Flights", function()
		if telemetry.IsLikeEmpty and telemetry.IsLikeEmpty() then
			logInfo("No telemetry loaded.")
			return
		end

		local pilotPropertyIndex = telemetry.GetObjectsTextPropertyIndex("Pilot", false)
		local callSignPropertyIndex = telemetry.GetObjectsTextPropertyIndex("CallSign", false)
		local typePropertyIndex = telemetry.GetObjectsTextPropertyIndex("Type", false)
		local namePropertyIndex = telemetry.GetObjectsTextPropertyIndex("Name", false)
		if namePropertyIndex == telemetry.InvalidPropertyIndex then
			namePropertyIndex = nil
		end

		local propertyIndexByName =
		{
			pilot = pilotPropertyIndex,
			callSign = callSignPropertyIndex,
			type = typePropertyIndex,
			name = namePropertyIndex,
		}

		local humanObjects = scanHumanObjects(propertyIndexByName)
		local flightKeys, indexByKey = buildFlightIndexByKey(humanObjects)
		local representativeCallSignByFlightKey = buildRepresentativeCallSignByFlightKey(humanObjects)

		logInfo(("Humans=%d Flights=%d"):format(#humanObjects, #flightKeys))
		for i, fk in ipairs(flightKeys) do
			local leadCallSign = (representativeCallSignByFlightKey and representativeCallSignByFlightKey[fk]) or (fk .. "1")
			local c = getFlightColorValue(i) or "(none)"
			logInfo(("%02d %s -> %s (%s)"):format(i, fk, leadCallSign, c))
		end
	end)

	Tacview.UI.Menus.SetOption(state.menuAutoAssign, getAddonSettingBoolean(SETTINGS.AUTO_ASSIGN_ON_LOAD, true))
	Tacview.UI.Menus.SetOption(state.menuShowLegend, getAddonSettingBoolean(SETTINGS.SHOW_LEGEND, true))
	Tacview.UI.Menus.SetOption(state.menuFixedWingOnly, getAddonSettingBoolean(SETTINGS.FIXED_WING_ONLY, true))
	Tacview.UI.Menus.SetOption(state.menuColorizeMissiles, getAddonSettingBoolean(SETTINGS.COLORIZE_MISSILES, true))
	Tacview.UI.Menus.SetOption(state.menuRenameMissiles, getAddonSettingBoolean(SETTINGS.RENAME_MISSILES, true))

	if Tacview.Events then
		registerEventListener(Tacview.Events.Update, onUpdate)
		registerEventListener(Tacview.Events.DrawTransparentUI, drawLegend)
		registerEventListener(Tacview.Events.DrawOpaqueUI, drawLegend)
		registerEventListener(Tacview.Events.DrawUI, drawLegend)
		registerEventListener(Tacview.Events.Shutdown, function()
			local renderer = Tacview.UI and Tacview.UI.Renderer or nil
			if not renderer then
				return
			end

			if state.legendRenderStateHandle and renderer.ReleaseRenderState then
				renderer.ReleaseRenderState(state.legendRenderStateHandle)
				state.legendRenderStateHandle = nil
			end
			if state.legendBackgroundRenderStateHandle and renderer.ReleaseRenderState then
				renderer.ReleaseRenderState(state.legendBackgroundRenderStateHandle)
				state.legendBackgroundRenderStateHandle = nil
			end
			if state.legendBackgroundVertexArrayHandle and renderer.ReleaseVertexArray then
				renderer.ReleaseVertexArray(state.legendBackgroundVertexArrayHandle)
				state.legendBackgroundVertexArrayHandle = nil
			end
			if state.legendSwatchVertexArrayHandle and renderer.ReleaseVertexArray then
				renderer.ReleaseVertexArray(state.legendSwatchVertexArrayHandle)
				state.legendSwatchVertexArrayHandle = nil
			end
			if state.processingRenderStateHandle and renderer.ReleaseRenderState then
				renderer.ReleaseRenderState(state.processingRenderStateHandle)
				state.processingRenderStateHandle = nil
			end
			if state.processingBackgroundRenderStateHandle and renderer.ReleaseRenderState then
				renderer.ReleaseRenderState(state.processingBackgroundRenderStateHandle)
				state.processingBackgroundRenderStateHandle = nil
			end
			if state.processingBackgroundVertexArrayHandle and renderer.ReleaseVertexArray then
				renderer.ReleaseVertexArray(state.processingBackgroundVertexArrayHandle)
				state.processingBackgroundVertexArrayHandle = nil
			end
			state.processingBackgroundWidth = nil
			state.processingBackgroundHeight = nil

			if renderer.ReleaseRenderState then
				for colorId, handle in pairs(state.legendSwatchRenderStateById) do
					renderer.ReleaseRenderState(handle)
					state.legendSwatchRenderStateById[colorId] = nil
				end
			end
		end)
	end

	if #state.legendLines == 0 then
		state.legendLines =
		{
			ADDON_TITLE.." ("..ADDON_VERSION..")",
			"Legend enabled",
			"Run: "..ADDON_TITLE.." -> Assign Colors Now",
		}
	end

	logInfo("Loaded (", TacviewApiName, ").")
end

Initialize()
