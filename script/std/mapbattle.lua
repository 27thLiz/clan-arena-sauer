--[[

  Mapbattle script - A heavenly approach to sanity

	notes:
		- as mapbattle is designed for public servers, only PRIV_ADMIN can force a mapchange
		- custom maprotation can be provided on load with  require"mapbattle".rotation(rot)  , else the one below is used. rot must be a string with maps seperated by whitespace, preferably the same as provided with cs.maprotation("mode", rot)

]]--

-- maplist copied from data/menus.cfg
local ffamaps, capturemaps, ctfmaps = table.concat({
  "aard3c academy akaritori alithia alloy aqueducts arbana bvdm_01 castle_trap collusion complex corruption curvedm curvy_castle darkdeath deathtek depot",
  "dirtndust DM_BS1 dock douze duel7 duel8 dune elegy fanatic_quake force fragplaza frostbyte frozen fury guacamole gubo hades",
"hashi hog2 industry injustice island justice kalking1 katrez_d kffa killfactory kmap5 konkuri-to ksauer1 legazzo lostinspace masdm mbt10",
  "mbt2 mbt9 memento metl2 metl3 metl4 moonlite neondevastation neonpanic nmp8 nucleus oasis oddworld ogrosupply orbe orion osiris",
  "ot outpost paradigm park pgdm phosgene pitch_black powerplant refuge renegade rm5 roughinery ruby ruine sauerstruck sdm1 shadowed",
  "shindou shinmei1 shiva simplicity skrdm1 stemple suburb tartech teahupoo tejen thetowers thor torment tumwalk turbine wake5 wdcd"
}, " "), table.concat({
  "abbey akroseum alithia arabic asgard asteroids c_egypt c_valley campo capture_night caribbean collusion core_refuge core_transfer corruption cwcastle damnation",
  "dirtndust donya duomo dust2 eternal_valley evilness face-capture fb_capture fc3 fc4 fc5 forge frostbyte hades hallo haste hidden",
  "infamy killcore3 kopenhagen lostinspace mbt12 mercury monastery nevil_c nitro nmp4 nmp8 nmp9 nucleus ogrosupply paradigm ph-capture reissen",
  "relic river_c serenity snapper_rocks spcr subterra suburb tempest tortuga turbulence twinforts urban_c valhalla venice xenon"
}, " "), table.concat({
  "abbey akroseum arbana asgard authentic autumn bad_moon berlin_wall bt_falls campo capture_night catch22 core_refuge core_transfer damnation desecration dust2",
  "eternal_valley europium evilness face-capture flagstone forge forgotten garden hallo haste hidden infamy kopenhagen l_ctf mach2 mbt1 mbt12",
  "mbt4 mercury mill nitro nucleus recovery redemption reissen sacrifice shipwreck siberia snapper_rocks spcr subterra suburb tejen tempest",
  "tortuga turbulence twinforts urban_c valhalla wdcd xenon fc4 fc5 gubo donya duomo"
}, " ")

-- load required libs
local abuse, playermsg, iterators, commands = require"std.abuse", require"std.playermsg", require"std.iterators", require"std.commands"
local L, fp = require"utils.lambda", require"utils.fp"

-- string to list
local function str_to_l (bigstring)	return fp.map.lf(L"_", bigstring:gmatch("%S+")) end
ffamaps, capturemaps, ctfmaps = str_to_l(ffamaps), str_to_l(capturemaps), str_to_l(ctfmaps)

-- make hybrid table from the maprotation
local function prius (list) return fp.map.tsi(list, L"_2", list) end
ffamaps, capturemaps, ctfmaps = prius(ffamaps), prius(capturemaps), prius(ctfmaps)

local maprotation = {}
local function rotation (rot) -- argument must be a string!
	maprotation = prius(str_to_l(rot)) or nil
end

-- retrieves the current maprotation
local function get_curmaprotation ()
	if cs.lockmaprotation ~= 2 then return end
	if next(maprotation) then return maprotation
	else return server.m_ctf and ctfmaps or server.m_capture and capturemaps or ffamaps
	end
end

-- validate if map is part of the maprotation
local function validate_map (map) local rot = get_curmaprotation(); return rot[map] end

-- toggled with #mapbattle, when off map votes go through the normal engine voting
local enabled = true

local function registervote (info)
	if not enabled then return end
	-- if server.mastermode < server.MM_LOCKED then return end
	if info.ci.privilege == server.PRIV_ADMIN then return end
	if info.text ~= server.smapname and server.m_valid(info.reqmode) and validate_map(info.text) then
		info.ci.extra.mapvote = info.text
		playermsg("\f7[\f1MAPBATTLE\f7] Your vote was \f0accepted\f7 into map battle pool!", info.ci)
	else playermsg("\f7[\f1MAPBATTLE\f7] \f3Error\f7! your vote was \f3not\f7 accepted into the map battle pool.", info.ci)
	end
	info.skip = true
end
spaghetti.addhook(server.N_MAPVOTE, registervote)

-- delay the intermission for X amount of milliseconds
local function delayinterm (time) server.interm = server.interm + time end

-- mapbattle struct
local mb = {
	startdelay = 3000, -- delay the mapbattle after intermission start
	battletime = 10000, -- keep in mind normal interm time is already 10 sec
	suddendeathtime = 5000,

	-- the following vars need to be cleaned up!
	map1 = nil,
	map2 = nil,
	winner = nil, -- cleaned with changemap hook
	votes = {
		map1 = 0,	-- only in catchvotes and mapbattle_cleanup and count_votes
		map2 = 0,	-- or don't remove as we need a number how many votes are currently voted for
		mapvotes = {}
	},
	running = false
}

-- catch votes during mapbattle
local function catchvotes(info)
	if not mb.running then return end
	if info.ci.state.state == engine.CS_SPECTATOR then playermsg("\f7[\f1MAPBATTLE\f7] Spectators are \f3not\f3 allowed to participate in the vote!", info.ci); return end

	if not info.ci.extra.voted then
		if tonumber(info.text) == 1 then
			mb.votes.map1 = mb.votes.map1 +1
			info.ci.extra.voted = 1
			server.sendservmsg("\f7[\f1MAPBATTLE\f7] " .. info.ci.name .. " voted for\f0 " .. mb.map1 .. "\f7")
		elseif tonumber(info.text) == 2 then
			mb.votes.map2 = mb.votes.map2 +1
			info.ci.extra.voted = 2
			server.sendservmsg("\f7[\f1MAPBATTLE\f7] " .. info.ci.name .. " voted for\f0 " .. mb.map2 .. "\f7")
		end
	else
		if info.ci.extra.voted == 2 and tonumber(info.text) == 1 then
			mb.votes.map1, mb.votes.map2 = mb.votes.map1 +1, mb.votes.map2 -1
			info.ci.extra.voted = 1
			server.sendservmsg("\f7[\f1MAPBATTLE\f7] " .. info.ci.name .. " changed his vote to\f0 " .. mb.map1 .. "\f7")
		elseif info.ci.extra.voted == 1 and tonumber(info.text) == 2 then
			mb.votes.map1, mb.votes.map2 = mb.votes.map1 -1, mb.votes.map2 +1
			info.ci.extra.voted = 2
			server.sendservmsg("\f7[\f1MAPBATTLE\f7] " .. info.ci.name .. " changed his vote to\f0 " .. mb.map2 .. "\f7")
		elseif tonumber(info.text) == 1 or tonumber(info.text) == 2 then playermsg("\f7[\f1MAPBATTLE\f7] Sorry, you have \f3only one vote\f7! You may \f0change\f7 it though...", info.ci) end
	end

	if tonumber(info.text) == 1 or tonumber(info.text) == 2 then
		if mb.votes.map1 > mb.votes.map2 then server.sendservmsg("\f7[\f1MAPBATTLE\f7] "..mb.map1..": \f0"..mb.votes.map1.."\f7 vs "..mb.map2..": \f3"..mb.votes.map2 .."\f7")
		elseif mb.votes.map1 < mb.votes.map2 then server.sendservmsg("\f7[\f1MAPBATTLE\f7] "..mb.map1..": \f3"..mb.votes.map1.." \f7vs "..mb.map2..": \f0"..mb.votes.map2 .."\f7")
		else server.sendservmsg("\f7[\f1MAPBATTLE\f7] "..mb.map1..": \f2"..mb.votes.map1.." \f7vs "..mb.map2..": \f2"..mb.votes.map2 .."\f7")	end
	end
end
spaghetti.addhook(server.N_TEXT, catchvotes)

local function mapbattle_cleanup ()
	-- called on changemap
	mb.map1, mb.map2, mb.winner = nil, nil, nil
	mb.votes.map1, mb.votes.map2 = 0,0 -- oohu, oohu, owl!
	mb.votes.mapvotes = {}
	for ci in iterators.all() do ci.extra.mapvote, ci.extra.voted = nil, nil end
end

-- and the winner is
local function count_votes()
	if mb.votes.map1 > mb.votes.map2 then return mb.map1
	elseif mb.votes.map1 < mb.votes.map2 then return mb.map2
	else return nil end
end

local function mapbattle_finalize ()
	if not mb.winner then
		local rot = get_curmaprotation()
		mb.winner = rot[math.random(#rot)]
		server.sendservmsg("\n\f7[\f1MAPBATTLE\f7] \f4SUDDEN DEATH \f3TIE\f7! Selecting a random map: \f0" .. mb.winner .."\f7\n")
	else server.sendservmsg("\n\f7[\f1MAPBATTLE\f7] Winner: \f0" .. mb.winner .. "\f7\n") end
	mb.running = false
	delayinterm(1000)
end

local function suddendeath ()
	delayinterm(mb.suddendeathtime)
	server.sendservmsg("\n\f7[\f1MAPBATTLE\f7] It's a \f3TIE\f7! \f4SUDDEN DEATH\f7! Vote again fast!!! \f0" .. mb.map1 .. "\f7 (1) versus \f0" .. mb.map2 .. "\f7 (2)")
	for ci in iterators.players() do ci.extra.voted = nil end

	spaghetti.latergame(mb.suddendeathtime , function() mb.winner = count_votes(); mapbattle_finalize() end)
end

local function mapbattle_winner ()
	mb.winner = count_votes()
	if not mb.winner then suddendeath()	else mapbattle_finalize() end
end

spaghetti.addhook("prechangemap", function (info) if mb.winner then info.map = mb.winner end end)
spaghetti.addhook("changemap", mapbattle_cleanup)

local function player_cleanup (info)
	info.ci.extra.mapvote = nil
	info.ci.extra.voted = nil
end

spaghetti.addhook("clientdisconnect", player_cleanup)
-- unspectating keeps the vote, clan arena unbenches dead players every round
spaghetti.addhook("specstate", function (info)
	if info.ci.state.state ~= engine.CS_SPECTATOR then return end
	player_cleanup(info)
	playermsg("\f7[\f1MAPBATTLE\f7] Your mapvote has been \f3removed\f7! Only players may participate in voting!", info.ci)
end)

-- fight!
local function mapbattle (maps)
	maps = mb.votes.mapvotes
	mb.running = true
	delayinterm(mb.battletime + 100)

	if not next(maps, next(maps)) then -- get a second battlemap (and a first one without votes) from the current maprotation
		local rot, tries = get_curmaprotation(), 0
		mb.map1 = next(maps) or rot[math.random(#rot)]
		repeat
			mb.map2, tries = rot[math.random(#rot)], tries + 1
		until mb.map1 ~= mb.map2 or tries >= 10
	else -- select highest voted map as map1 and slip in a counter
		local c, mcount = 0,0 -- oohu, oohu, owl!
		for k, v in pairs(maps) do mcount = mcount + 1; if v > c then mb.map1, c = k, v end end
		maps[mb.map1] = nil
		-- and select second battle maps randomly from the pool of votes
		local secondary_maps = fp.map.lp(L"_", maps)
		mb.map2 = secondary_maps[math.random(mcount-1)]
	end

	server.sendservmsg("\n\f7[\f1MAPBATTLE\f7]    \f0" .. mb.map1 .. "\f7 (\f91)  \f7vs.  \f0" .. mb.map2 .. "\f7 (\f92) \n\f7[\f1MAPBATTLE\f7] Cast your votes now!\n")

	spaghetti.latergame(mb.battletime+10000, mapbattle_winner) -- I told you to remember 10000 ms from the engine!
end

-- collect the mapvotes at intermission and initiate mapbattle, maps missing from the votes are picked randomly
local function check_map_votes (info)
	if not enabled or not get_curmaprotation() then return end
	for ci in iterators.select(L"_.extra.mapvote") do mb.votes.mapvotes[ci.extra.mapvote] = 1 + (mb.votes.mapvotes[ci.extra.mapvote] or 0) end
	delayinterm(mb.startdelay)
	spaghetti.latergame(mb.startdelay, mapbattle)
end
spaghetti.addhook("intermission", check_map_votes)

commands.add("mapbattle", function(info)
	if info.ci.privilege < server.PRIV_MASTER then return playermsg("Access denied.", info.ci) end
	local arg = info.args == "" and (enabled and 0 or 1) or tonumber(info.args)
	if arg ~= 0 and arg ~= 1 then return playermsg("Usage: #mapbattle [0|1]", info.ci) end
	if enabled == (arg == 1) then
		return playermsg("\f7[\f1MAPBATTLE\f7] is already " .. (enabled and "enabled" or "disabled") .. ".", info.ci)
	end
	enabled = arg == 1
	server.sendservmsg(server.colorname(info.ci, nil) .. (enabled and " enabled" or " disabled") .. " \f7[\f1MAPBATTLE\f7] map voting at intermission.")
end, "#mapbattle [0|1]: toggle map voting at intermission, map suggestions battle it out (only masters)")

return { rotation = rotation }
