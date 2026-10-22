--[[

  Clan Arena: round based team elimination.
  Everyone spawns with every weapon and heavy armour, there are no items and no respawns during a round. The last team
  standing wins the round, first team to config.roundstowin rounds wins the map. Self-damage and friendly fire are off,
  so rocket/grenade jumping is free. Team score is rounds won, player frags/deaths stay real kills.
  Dead players are moved to spectator (benched) config.benchdelay seconds after dying and put back on their team when
  the next round starts.
  Mode must be effichold (all weapons, no items, teams, ctf radar), the hooks are no-ops in any other mode. Hold rather
  than ctf because clients pick team spawns in ctf, and ffa maps without them stack everyone on one spot.

]]--

local fp, L, iterators, playermsg, putf, spawn, setteamscore, settime, commands, sound, setteam, uuid = require"utils.fp", require"utils.lambda", require"std.iterators", require"std.playermsg", require"std.putf", require"std.spawn", require"std.setteamscore", require"std.settime", require"std.commands", require"std.sound", require"std.setteam", require"std.uuid"
local map = fp.map

require"std.notalive"

local module = {
  defaults = {
    roundstowin = 10,
    roundtime = 120,  -- seconds
    warmup = 10,      -- seconds, damage immune, movement allowed
    roundgap = 5,     -- seconds between rounds
    benchdelay = 2,   -- seconds from death to spectator, false = stay dead until next round
    health = 200,
    armour = 200,
    armourtype = server.A_YELLOW,
    ammo = nil,       -- nil = efficiency amounts, or { [server.GUN_RL] = n, ... }
    gunselect = server.GUN_CG,
    teams = { "good", "evil" },
    maxteamdiff = 1   -- largest team size difference tolerated at round start, false = no autobalance
  }
}

local hooks, laters, config, enabled, balance = {}, {}
local phase, wins, round, lastwarned, restoring = "ended", {}, 0, {}, false
local tryround, endround

-- timers are tracked by key and forgotten when they fire, so a stale token is never cancelled
local function later(key, delay, fn)
  if laters[key] then spaghetti.cancel(laters[key]) end
  laters[key] = spaghetti.latergame(delay, function()
    laters[key] = nil
    fn()
  end)
end

local function cancellaters()
  for _, l in pairs(laters) do spaghetti.cancel(l) end
  laters = {}
end

local function teamname(team)
  return (team == config.teams[1] and "\f1" or "\f3") .. team .. "\f7"
end

local function isteam(team)
  return team == config.teams[1] or team == config.teams[2]
end

local function present(team)
  local n = 0
  for ci in iterators.players() do if ci.team == team then n = n + 1 end end
  for ci in iterators.spectators() do if ci.extra.cabench == team then n = n + 1 end end
  return n
end

-- alive count, sum of health + armour, and one of the alive players
local function alive(team)
  local n, hp, last = 0, 0
  for ci in iterators.players() do
    if ci.team == team and ci.state.state == engine.CS_ALIVE then
      n, hp, last = n + 1, hp + ci.state.health + ci.state.armour, ci
    end
  end
  return n, hp, last
end

local function bothpresent()
  return present(config.teams[1]) > 0 and present(config.teams[2]) > 0
end

local function scoreline()
  local t1, t2 = config.teams[1], config.teams[2]
  return ("(%s %d - %d %s)"):format(teamname(t1), wins[t1], wins[t2], teamname(t2))
end

-- kills add to teaminfo frags in the engine, put rounds won back
local function syncscores()
  for _, team in ipairs(config.teams) do setteamscore.set(team, wins[team]) end
end

local function forcedeath(ci)
  ci.state:respawn()
  ci.state.state = engine.CS_DEAD
  engine.sendpacket(-1, 1, putf({ 10, r = 1 }, server.N_FORCEDEATH, ci.clientnum):finalize(), -1)
end

local function inround()
  return phase == "warmup" or phase == "live"
end

-- server.forcespectator without aiman::removeai: a benched owner keeps simulating its bots, else with no other
-- human playing they would be left ownerless and frozen
local function bench(ci)
  if ci.state.aitype ~= server.AI_NONE or ci.state.state ~= engine.CS_DEAD or not inround() then return end
  ci.extra.cabench = ci.team
  if server.smode then server.smode:leavegame(ci, false) end
  ci.state.state = engine.CS_SPECTATOR
  ci.state.timeplayed = ci.state.timeplayed + engine.lastmillis - ci.state.lasttimeplayed
  engine.sendpacket(-1, 1, putf({ 10, r = 1 }, server.N_SPECTATOR, ci.clientnum, 1):finalize(), -1)
  playermsg("\f2You are spectating until the next round.", ci)
end

local function unbenchall()
  if not enabled then return end
  for ci in iterators.spectators() do
    local team = ci.extra.cabench
    if team then
      ci.extra.cabench = nil
      restoring = true
      server.unspectate(ci)
      restoring = false
      if isteam(team) and ci.team ~= team then setteam.set(ci, team, -1) end
    end
  end
end

-- move the lowest fraggers of the bigger team over, bots are left to the engine bot balance
local function balanceteams()
  if not balance then return end
  local maxdiff = config.maxteamdiff or 1
  local t1, t2 = config.teams[1], config.teams[2]
  while true do
    local n = { [t1] = 0, [t2] = 0 }
    for ci in iterators.players() do if isteam(ci.team) then n[ci.team] = n[ci.team] + 1 end end
    if math.abs(n[t1] - n[t2]) <= maxdiff then return end
    local from = n[t1] > n[t2] and t1 or t2
    local to = from == t1 and t2 or t1
    local worst
    for ci in iterators.players() do
      if ci.team == from and ci.state.aitype == server.AI_NONE and (not worst or ci.state.frags < worst.state.frags) then worst = ci end
    end
    if not worst then return end
    setteam.set(worst, to, -1, true)  -- keepalive, everyone respawns right after anyway
    server.sendservmsg(("%s\f7 was moved to %s to balance the teams."):format(server.colorname(worst, nil), teamname(to)))
  end
end

local function startround()
  cancellaters()
  unbenchall()
  balanceteams()
  round, phase, lastwarned = round + 1, "warmup", {}
  for ci in iterators.players() do
    if ci.state.state == engine.CS_ALIVE then
      ci.state:respawn()
      server.sendspawn(ci)
    else spawn(ci) end
  end
  server.sendservmsg(("\f2Round %d\f7 %s - weapons free in \f0%d\f7 seconds!"):format(round, scoreline(), config.warmup))
  later("warmup", config.warmup * 1000, function()
    if phase ~= "warmup" then return end
    phase = "live"
    server.sendservmsg("\f3FIGHT!")
    for ci in iterators.clients() do sound(ci, server.S_V_FIGHT, true) end
  end)
  later("timeout", (config.warmup + config.roundtime) * 1000, function()
    if phase ~= "live" then return end
    local t1, t2 = config.teams[1], config.teams[2]
    local a1, hp1 = alive(t1)
    local a2, hp2 = alive(t2)
    server.sendservmsg("\f2Time's up!")
    if a1 ~= a2 then return endround(a1 > a2 and t1 or t2) end
    if hp1 ~= hp2 then return endround(hp1 > hp2 and t1 or t2) end
    endround(nil)
  end)
end

function tryround()
  cancellaters()
  if bothpresent() then return startround() end
  if phase == "freeplay" then return end
  phase = "freeplay"
  server.sendservmsg("\f2Clan Arena\f7: waiting for players on both teams, free play until then.")
end

function endround(winner)
  cancellaters()
  phase = "ended"
  if not winner then
    server.sendservmsg(("\f2Round %d is a draw!\f7 %s"):format(round, scoreline()))
  else
    wins[winner] = wins[winner] + 1
    syncscores()
    server.sendservmsg(("%s wins round %d! %s - %d alive"):format(teamname(winner), round, scoreline(), (alive(winner))))
    if wins[winner] >= config.roundstowin then
      server.sendservmsg(teamname(winner) .. " \f2wins the match!")
      return server.startintermission()
    end
  end
  later("next", config.roundgap * 1000, tryround)
end

local function checkround()
  if phase == "freeplay" then
    if not laters.next and bothpresent() then
      server.sendservmsg("\f2Both teams have players, round starting soon!")
      later("next", 3000, tryround)
    end
    return
  end
  if phase ~= "warmup" and phase ~= "live" then return end
  if not bothpresent() then
    server.sendservmsg("\f2Round cancelled, a team is empty.")
    return tryround()
  end
  local t1, t2 = config.teams[1], config.teams[2]
  local a1, a2 = alive(t1), alive(t2)
  if a1 == 0 or a2 == 0 then return endround(a1 > 0 and t1 or a2 > 0 and t2 or nil) end
  for _, team in ipairs(config.teams) do
    local n, _, last = alive(team)
    if n == 1 and not lastwarned[team] and present(team) > 1 then
      lastwarned[team] = true
      -- bots have no peer, sending to their clientnum crashes the engine
      if last.state.aitype ~= server.AI_BOT then playermsg("\f3You are the last one standing!", last) end
    end
  end
end

-- defer to after the engine finished processing (team changes, disconnects, simultaneous deaths)
local function queuecheck()
  if enabled then later("check", 1, checkround) end
end

-- returns true if the client will be benched, the timer dies with the round on cancellaters()
local function schedulebench(ci)
  if not config.benchdelay or ci.state.aitype ~= server.AI_NONE or not inround() then return false end
  local id, r = ci.extra.uuid, round
  later("bench" .. id, config.benchdelay * 1000, function()
    local ci = uuid.find(id)
    if ci and round == r then bench(ci) end
  end)
  return true
end

local function blockteams(info)
  if info.skip or not enabled then return end
  local team = engine.filtertext(info.text, false):sub(1, server.MAXTEAMLEN)
  if not isteam(team) then
    info.skip = true
    playermsg("Clan Arena teams are " .. teamname(config.teams[1]) .. " and " .. teamname(config.teams[2]) .. ".", info.ci)
  elseif (phase == "warmup" or phase == "live") and info.ci.privilege < server.PRIV_ADMIN then
    info.skip = true
    playermsg("\f3You cannot switch teams during a round, wait for it to end.", info.ci)
  else queuecheck() end
end

function module.on(cfg)
  map.np(L"spaghetti.removehook(_2)", hooks)
  hooks = {}
  cancellaters()
  enabled, phase = false, "ended"
  if not cfg then return end
  config = {}
  for k, v in pairs(module.defaults) do config[k] = v end
  for k, v in pairs(cfg) do config[k] = v end
  balance = config.maxteamdiff ~= false

  hooks.changemap = spaghetti.addhook("changemap", function()
    laters = {}  -- game laters are freed by the engine on map change
    enabled, phase, round = server.m_efficiency and server.m_hold, "ended", 0
    if not enabled then return end
    wins = { [config.teams[1]] = 0, [config.teams[2]] = 0 }
    syncscores()
    settime.set(24 * 60 * 60 * 1000)
    tryround()
  end)
  hooks.prechangemap = spaghetti.addhook("prechangemap", function() cancellaters() phase = "ended" unbenchall() end)
  hooks.intermission = spaghetti.addhook("intermission", function() cancellaters() phase = "ended" unbenchall() end)

  hooks.spawnstate = spaghetti.addhook("spawnstate", function(info)
    if info.skip or not enabled then return end
    info.skip = true
    local st = info.ci.state
    st.health, st.maxhealth, st.armourtype, st.armour = config.health, config.health, config.armourtype, config.armour
    if config.ammo then
      for gun = server.GUN_SG, server.GUN_PISTOL do st.ammo[gun] = config.ammo[gun] or 0 end
    else
      for gun = server.GUN_SG, server.GUN_GL do st:baseammo(gun, 2, 1) end
      st.ammo[server.GUN_CG] = math.floor(st.ammo[server.GUN_CG] / 2)
    end
    st.gunselect = config.gunselect
    st.lifesequence = (st.lifesequence + 1) % 0x80
    info.ci.extra.caround = round
  end)

  hooks.dodamage = spaghetti.addhook("dodamage", function(info)
    if info.skip or not enabled then return end
    local target, actor = info.target, info.actor
    if phase == "warmup" or target.clientnum == actor.clientnum or target.team == actor.team then
      info.skip, info.damage = true, 0
    end
  end)

  hooks.tryspawn = spaghetti.addhook(server.N_TRYSPAWN, function(info)
    if info.skip or not enabled or phase == "freeplay" then return end
    -- late joiners may spawn during warmup, once per round
    if phase == "warmup" and info.cq and info.cq.extra.caround ~= round then return end
    info.skip = true
  end)

  hooks.notalive = spaghetti.addhook("notalive", function(info)
    if not enabled then return end
    syncscores()
    queuecheck()
    schedulebench(info.ci)
  end)
  hooks.clientdisconnect = spaghetti.addhook("clientdisconnect", queuecheck)
  hooks.botleave = spaghetti.addhook("botleave", queuecheck)
  hooks.botjoin = spaghetti.addhook("botjoin", queuecheck)

  hooks.specstate = spaghetti.addhook("specstate", function(info)
    if not enabled or restoring then return end
    local ci = info.ci
    if ci.state.state ~= engine.CS_SPECTATOR then
      if phase == "warmup" then spawn(ci)
      elseif phase ~= "freeplay" and not schedulebench(ci) then playermsg("\f2Round in progress, you will spawn next round.", ci) end
    end
    queuecheck()
  end)
  hooks.connected = spaghetti.addhook("connected", function(info)
    if not enabled then return end
    local ci = info.ci
    -- the welcome packet spawns non spectators, take it back mid-round
    if ci.state.state ~= engine.CS_SPECTATOR and phase ~= "warmup" and phase ~= "freeplay" then
      forcedeath(ci)
      if not schedulebench(ci) then playermsg("\f2Round in progress, you will spawn next round.", ci) end
    end
    queuecheck()
  end)

  -- benched players come back on round start, spectating again opts out of that
  hooks.spectator = spaghetti.addhook(server.N_SPECTATOR, function(info)
    if info.skip or not enabled or not info.spinfo or not info.spinfo.extra.cabench then return end
    if info.spectator ~= info.sender and info.ci.privilege == server.PRIV_NONE then return end
    info.skip = true
    if info.val == 0 then playermsg("\f2You will be back next round.", info.spinfo) return end
    info.spinfo.extra.cabench = nil
    playermsg("\f2You will stay in spectator.", info.spinfo)
    queuecheck()
  end)

  -- the hold mode is only there for the radar, the flag stays put
  local function blockflags(info) if enabled then info.skip = true end end
  hooks.takeflag = spaghetti.addhook(server.N_TAKEFLAG, blockflags)
  hooks.trydropflag = spaghetti.addhook(server.N_TRYDROPFLAG, blockflags)

  hooks.setteam = spaghetti.addhook(server.N_SETTEAM, blockteams)
  hooks.switchteam = spaghetti.addhook(server.N_SWITCHTEAM, blockteams)

  commands.add("balance", function(info)
    if info.ci.privilege < server.PRIV_MASTER then return playermsg("Access denied.", info.ci) end
    local arg = info.args == "" and (balance and 0 or 1) or tonumber(info.args)
    if arg ~= 0 and arg ~= 1 then return playermsg("Usage: #balance [0|1]", info.ci) end
    if balance == (arg == 1) then
      return playermsg("\f2Team autobalance\f7 is already " .. (balance and "enabled" or "disabled") .. ".", info.ci)
    end
    balance = arg == 1
    server.sendservmsg(server.colorname(info.ci, nil) .. (balance and " enabled" or " disabled") .. " \f2team autobalance\f7 at round start.")
  end, "#balance [0|1]: toggle moving players between teams at round start to even them out (only masters)")

  commands.add("rules", function(info)
    playermsg("\f2Clan Arena\f7: everyone spawns with every weapon, " .. config.health .. " health and " .. config.armour .. " armour. There are no items.", info.ci)
    playermsg("\f7No respawns during a round: eliminate the other team to win it. First team to \f0" .. config.roundstowin .. "\f7 rounds wins the map.", info.ci)
    playermsg("\f7No self-damage (rocket/grenade jump freely) and no friendly fire. Rounds last " .. config.roundtime .. "s, then the team with more players alive wins.", info.ci)
    playermsg("\f7Dead players spectate until the next round. Use \f0/spectator 1\f7 while spectating to stay out.", info.ci)
  end, "#rules: Clan Arena rules")
end

return module
