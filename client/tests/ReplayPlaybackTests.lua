local ClientMatch = require("client.src.ClientMatch")
local ReplayPlayback = require("client.src.ReplayPlayback")
local ReplayCheckpointStore = require("client.src.ReplayCheckpointStore")
local ReplayV3 = require("common.data.ReplayV3")
local FileUtils = require("client.src.FileUtils")
local logger = require("common.lib.logger")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local ReplayGame = require("client.src.scenes.ReplayGame")
local input = require("client.src.inputManager")
local tableUtils = require("common.lib.tableUtils")

local replayDirectory = "common/tests/engine/replays/"
local shortReplay = "v046-2023-01-28-02-39-32-JamBox-L10-vs-Galadic97-L10-Casual-P1wins.txt"
local longReplay = "10min-v046-2022-07-25-00-23-46-Geminorum-L10-vs-Zyza-L10-Casual-P1wins.txt"

local function assertSame(actual, expected, path)
  if type(expected) ~= "table" then
    assert(actual == expected, path .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
    return
  end
  assert(type(actual) == "table", path .. ": expected table")
  for key, value in pairs(expected) do
    assertSame(actual[key], value, path .. "." .. tostring(key))
  end
  for key in pairs(actual) do
    assert(expected[key] ~= nil, path .. ": unexpected key " .. tostring(key))
  end
end

local function snapshot(match)
  local result = {}
  for i, stack in ipairs(match.stacks) do
    local copy = {}
    stack.engine:saveIntoRollbackCopy(copy)
    result[i] = {engine = copy, analytic = stack.analytic and stack.analytic.data}
  end
  return deepcpy(result)
end

local function withReplay(name, test, useScene)
  local replay = type(name) == "table" and name or ReplayV3.createFromTable(FileUtils.readJsonFile(replayDirectory .. name), true)
  local match = ClientMatch.createFromReplay(replay)
  match.supportsPause = true
  match.renderDuringPause = true
  if not useScene then
    match:removeCanvases()
  end
  match:start()
  local scene = useScene and ReplayGame({match = match})
  local playback = scene and scene.playback or ReplayPlayback(match)
  match.replayPlayback = playback
  local success, message = xpcall(function()
    test(match, playback, scene)
  end, debug.traceback)
  match:deinit()
  assert(next(playback.store.checkpoints) == nil, "Replay checkpoint history was not released")
  assert(playback.store.compressedBytes == 0, "Released checkpoint data is still counted")
  assert(playback.store.cachedCheckpoint == nil, "Decoded checkpoint was not released")
  assert(success, message)
end

local function runUntil(playback, frame)
  while playback.match.engine.clock < frame do
    assert(not playback.match.engine:hasEnded(), "Replay ended before frame " .. frame)
    playback:run()
  end
  assert(playback.match.engine.clock == frame, "Playback skipped the requested frame")
end

local function seek(playback, frame)
  playback:rewindToFrame(frame)
  local updates = 0
  while playback.seekTarget do
    playback:updateSeek(1)
    updates = updates + 1
    assert(updates < 1000, "Replay seek did not finish")
  end
  assert(playback.match.engine.clock == math.max(0, frame), "Seek stopped on the wrong frame")
end

local function withoutCheckpointFileIO(test)
  local originalFunctions = {}
  for _, name in ipairs({"createDirectory", "getInfo", "write", "read", "remove"}) do
    originalFunctions[name] = love.filesystem[name]
    love.filesystem[name] = function()
      error("Checkpoint storage must not use the filesystem")
    end
  end
  local success, message = xpcall(test, debug.traceback)
  for name, original in pairs(originalFunctions) do
    love.filesystem[name] = original
  end
  assert(success, message)
end

local function testCheckpointEncoding()
  local store = ReplayCheckpointStore(600)
  local chain = {height = 3, linkTimes = {[0] = 15, [30] = 100}}
  local data = {currentChain = chain, stagedGarbage = {chain}, fraction = 1 / 3, binary = "\0\255", flag = false}
  data.self = data
  store:save(0, data)
  assert(type(store.checkpoints[0]) == "string", "Checkpoint history should contain compressed bytes")
  chain.height = 99
  local loaded = store:load(0)
  assert(loaded.currentChain.height == 3, "Checkpoint retained mutable source data")
  assert(loaded.currentChain == loaded.stagedGarbage[1], "Checkpoint lost shared garbage references")
  assert(loaded.self == loaded, "Checkpoint lost cyclic references")
  assert(loaded.currentChain.linkTimes[0] == 15 and loaded.currentChain.linkTimes[30] == 100, "Numeric keys changed")
  assert(loaded.fraction == 1 / 3, "Checkpoint lost floating-point precision")
  assert(loaded.binary == data.binary and loaded.flag == false, "Checkpoint lost scalar data")
  assert(store:load(599) == loaded, "Checkpoint cache did not reuse its single entry")
  store:save(600, {clock = 600})
  assert(store.compressedBytes == #store.checkpoints[0] + #store.checkpoints[600], "Compressed byte count is incorrect")
  assert(store:load(600).clock == 600, "Checkpoint cache did not replace its entry")
  store:close()
  assert(next(store.checkpoints) == nil and store.compressedBytes == 0, "Compressed checkpoints were not released")
  assert(store.cachedCheckpoint == nil, "Decoded checkpoint was not released")
  store:close()
end

local function testCheckpointStoreCanBeGarbageCollected()
  local references = setmetatable({}, {__mode = "v"})
  do
    local store = ReplayCheckpointStore(60)
    store:save(0, {clock = 0})
    references[1] = store
  end
  collectgarbage("collect")
  assert(references[1] == nil, "Checkpoint store was retained after its owner was released")
end

local function testReconstructionMatchesUninterruptedPlayback()
  withReplay(shortReplay, function(match, playback)
    local expected = {}
    for _, frame in ipairs({0, 75, 443, 613, 1200, 1800}) do
      runUntil(playback, frame)
      expected[frame] = snapshot(match)
    end
    while not match.engine:hasEnded() do
      playback:run()
    end
    local endClock = match.engine.clock
    local expectedEnd = snapshot(match)

    local endCallbacks = 0
    match:connectSignal("matchEnded", expected, function()
      endCallbacks = endCallbacks + 1
    end)
    for _, frame in ipairs({1200, 613, 443, 75, 0}) do
      seek(playback, frame)
      assertSame(snapshot(match), expected[frame], "state@" .. frame)
      assert(not match.engine:hasEnded(), "Rewind retained cached match end state")
    end
    for _, frame in ipairs({1200, 1800, endClock}) do
      runUntil(playback, frame)
      assertSame(snapshot(match), expected[frame] or expectedEnd, "resumed@" .. frame)
    end
    assert(endCallbacks == 1, "Reconstruction duplicated match-end callbacks")
    seek(playback, 1200)
    assertSame(snapshot(match), expected[1200], "nonzero checkpoint restore")
    runUntil(playback, 1800)
    seek(playback, 1200)
    assertSame(snapshot(match), expected[1200], "reused nonzero checkpoint restore")
    seek(playback, 613)
    assertSame(snapshot(match), expected[613], "repeated checkpoint restore")
  end)
end

local function testFrameBoundariesAndPausedSeeking()
  withReplay(shortReplay, function(match, playback)
    runUntil(playback, 1200)
    local expected = snapshot(match)
    match.isPaused = true
    for _, frame in ipairs({600, 599, 300, 1, 0, -1}) do
      seek(playback, frame)
      assert(match.isPaused, "Seeking changed the replay's pause state")
    end
    match.isPaused = false
    runUntil(playback, 1200)
    assertSame(snapshot(match), expected, "replay after reaching frame zero")
  end)
end

local function testContinuousRewindCrossesBufferBoundaries()
  withReplay(shortReplay, function(match, playback)
    local initial = snapshot(match)
    runUntil(playback, 1800)
    local reconstructions = 0
    for frame = 1799, 0, -1 do
      playback:rewindToFrame(frame)
      if playback.seekTarget then
        reconstructions = reconstructions + 1
      end
      while not playback:updateSeek(1) do
      end
      assert(match.engine.clock == frame, "Continuous reverse playback skipped a frame")
    end
    assert(reconstructions > 1 and reconstructions < 12, "Reverse playback did not reuse reconstructed windows")
    assertSame(snapshot(match), initial, "continuous reverse playback to frame zero")
  end)
end

local function testClosingDuringReconstruction()
  withReplay(shortReplay, function(match, playback)
    runUntil(playback, 1800)
    playback:rewindToFrame(600)
    assert(playback.seekTarget, "Expected a seek in progress")
    playback:close()
    assert(playback.seekTarget == nil, "Closing playback did not cancel reconstruction")
    assert(next(playback.store.checkpoints) == nil, "Closing playback retained compressed checkpoints")
    assert(playback.store.cachedCheckpoint == nil, "Closing playback retained a decoded checkpoint")
    for _, stack in ipairs(match.stacks) do
      assert(not stack.isSeeking, "Closing playback did not clear its presentation guard")
    end
  end)
end

local function testSeekBudgetsAndSideEffects()
  withReplay(shortReplay, function(match, playback)
    runUntil(playback, 1800)
    playback:rewindToFrame(1200)
    assert(playback.seekTarget == 1200, "Expected reconstruction beyond the recent window")
    local checkpointClock = match.engine.clock
    assert(not playback:updateSeek(0), "A zero-budget seek should yield")
    assert(match.engine.clock == checkpointClock, "Zero-budget seek advanced the simulation")
    for _, stack in ipairs(match.stacks) do
      assert(not stack:canPlaySfx(), "Reconstruction allowed sound effects")
      assert(stack.card_q:len() == 0 and stack.pop_q:len() == 0, "Future effects survived checkpoint restoration")
    end
    local completed = playback:updateSeek(1)
    assert(not completed, "One batch should not simulate more than 240 frames")
    assert(match.engine.clock <= checkpointClock + 240, "Seek exceeded its frame budget")
    while not playback:updateSeek(1) do
    end
    for _, stack in ipairs(match.stacks) do
      assert(not stack.isSeeking, "Reconstruction did not release its presentation guard")
    end
  end)
end

local function testModernPanelGeneratorAndSimulatedOpponent()
  local replay = ReplayV3.createFromTable(FileUtils.readJsonFile(replayDirectory .. shortReplay), true)
  replay.panelSource = {sourceType = ReplayV3.panelSourceTypes.seedV2, seed = 1, shockEnabled = true}
  replay.rules = GameModes.getPreset("ONE_PLAYER_TRAINING").matchRules
  local playerStack = replay.stacks[1]
  ---@cast playerStack ReplayStack
  playerStack.inputs = "A2400"
  playerStack.levelData = deepcpy(LevelPresets.getModern(1))
  replay.stacks[2] = {
    stackType = ReplayV3.stackTypes.SimulatedStack,
    attackSettings = {
      delayBeforeStart = 0, delayBeforeRepeat = 3000, countdownAdjusted = true,
      attackPatterns = {{width = 3, height = 1, startTime = 1500}}
    },
    healthSettings = {framesToppedOutToLose = 300, lineClearGPM = 1, lineHeightToKill = 100, riseSpeed = 1}
  }
  replay.garbageFlows = {{source = 2, recipients = {1}}}
  withReplay(replay, function(match, playback)
    runUntil(playback, 700)
    local expected = snapshot(match)
    runUntil(playback, 1300)
    seek(playback, 700)
    assertSame(snapshot(match), expected, "modern generator and simulated health")
    seek(playback, 75)
    runUntil(playback, 700)
    assertSame(snapshot(match), expected, "modern generator after countdown rewind")
  end)
end

local function testReplaySceneControlsAndGameOver()
  withReplay(shortReplay, function(match, playback, scene)
    local originalIsDown = input.isDown
    local originalRepeat = input.isPressedWithRepeat
    local pressed
    input.isDown = {}
    input.isPressedWithRepeat = function(_, key)
      return pressed == key
    end
    local success, message = xpcall(function()
      assert(scene.playbackSpeeds[scene.playbackSpeedIndex] == 1, "Replay should still start at normal speed")
      local initialWins = {}
      for i, player in ipairs(match.players) do
        initialWins[i] = player.wins
      end
      runUntil(playback, 1800)
      for _, speed in ipairs({-1, -2, -3, -4, -8, -16}) do
        scene.playbackSpeedIndex = tableUtils.indexOf(scene.playbackSpeeds, speed)
        local clock = match.engine.clock
        scene:runGame()
        assert(not playback.seekTarget, "A cached reverse step unnecessarily started a seek")
        assert(match.engine.clock == clock + speed, "Reverse playback did not use the selected speed")
      end
      playback:rewindToFrame(600)
      input.isDown.Start = 1
      scene:runGame()
      input.isDown.Start = nil
      assert(match.isPaused, "Pause was ignored during reconstruction")
      while playback.seekTarget do
        scene:runGame()
      end
      assert(match.engine.clock == 600, "Scene did not complete its paused seek")
      scene:draw()

      scene.playbackSpeedIndex = tableUtils.indexOf(scene.playbackSpeeds, -16)
      pressed = "Swap1"
      scene:runGame()
      pressed = nil
      scene:runGame()
      assert(match.isPaused and match.engine.clock == 599, "Paused reverse frame advance failed")
      match.isPaused = false
      scene.playbackSpeedIndex = tableUtils.indexOf(scene.playbackSpeeds, 1)
      while not match.engine:hasEnded() do
        scene:runGame()
      end
      assert(match.ended, "Scene did not receive the match-end callback")
      local winner = match:getWinners()[1]
      local winnerIndex = winner.playerNumber
      assert(winner.wins == initialWins[winnerIndex] + 1, "Game over did not increment the winner once")
      scene.playbackSpeedIndex = tableUtils.indexOf(scene.playbackSpeeds, -16)
      local endClock = match.engine.clock
      scene:runGame()
      assert(not match.ended, "Scene did not rewind out of game over")
      assert(match.engine.clock == endClock - 16, "Fast rewind out of game over used the wrong speed")
      assert(winner.wins == initialWins[winnerIndex], "Rewinding out of game over did not undo the win")
      scene.playbackSpeedIndex = tableUtils.indexOf(scene.playbackSpeeds, 1)
      while not match.engine:hasEnded() do
        scene:runGame()
      end
      assert(winner.wins == initialWins[winnerIndex] + 1, "Replayed game over duplicated the win")

      scene.playbackSpeedIndex = tableUtils.indexOf(scene.playbackSpeeds, -16)
      local updates = 0
      local reconstructions = 0
      while match.engine.clock > 0 or playback.seekTarget do
        local wasSeeking = playback.seekTarget ~= nil
        local expectedFrame = playback.seekTarget or math.max(0, match.engine.clock - 16)
        scene:runGame()
        if not playback.seekTarget then
          assert(match.engine.clock == expectedFrame, "Fast reverse playback skipped the requested frame")
        elseif not wasSeeking then
          reconstructions = reconstructions + 1
        end
        updates = updates + 1
        assert(updates < 2000, "Fast reverse playback did not finish")
      end
      assert(reconstructions > 1, "Fast reverse playback did not cross checkpoint boundaries")
      assert(winner.wins == initialWins[winnerIndex], "Fast reverse playback did not undo the final win")
      scene:runGame()
      assert(match.engine.clock == 0, "Fast reverse playback went past the beginning")
    end, debug.traceback)
    input.isDown = originalIsDown
    input.isPressedWithRepeat = originalRepeat
    assert(success, message)
  end, true)
end

local function testTenMinuteReplayUsesCompressedHistory()
  withReplay(longReplay, function(match, playback)
    runUntil(playback, 18000)
    collectgarbage("collect")
    local halfwayMemory = collectgarbage("count")
    local originalBuffers = {}
    for i, stack in ipairs(match.stacks) do
      originalBuffers[i] = stack.engine.rollbackBuffer.buffer
    end
    runUntil(playback, 36000)
    local expected = snapshot(match)
    collectgarbage("collect")
    local endMemory = collectgarbage("count")
    local seekStart = love.timer.getTime()
    seek(playback, 18000)
    local seekSeconds = love.timer.getTime() - seekStart
    runUntil(playback, 36000)
    assertSame(snapshot(match), expected, "ten-minute replay after seeking")
    for i, stack in ipairs(match.stacks) do
      assert(stack.engine.rollbackBuffer.buffer == originalBuffers[i], "Seeking allocated a second rollback buffer")
      assert(#stack.engine.rollbackBuffer.buffer == stack.engine.rollbackBuffer.size, "Rollback storage grew")
    end
    assert(playback.store.interval == 60, "Replay checkpoints should be saved every second")
    assert(playback.store.latestFrame == 36000, "Checkpoints were not generated throughout the replay")
    assert(playback.store.cachedFrame == 17700, "Seek did not use the nearest checkpoint before the refill window")
    assert(endMemory - halfwayMemory < 16 * 1024, "Replay checkpoint RAM grew by more than 16 MiB over five minutes")
    local compressedBytes = 0
    for _, data in pairs(playback.store.checkpoints) do
      assert(type(data) == "string", "An uncompressed checkpoint was retained in history")
      compressedBytes = compressedBytes + #data
    end
    assert(playback.store.compressedBytes == compressedBytes, "Checkpoint byte count does not match retained data")
    assert(compressedBytes < 12 * 1024 * 1024, "Ten-minute replay used more than 12 MiB of compressed checkpoints")
    logger.info(string.format(
      "Replay rewind: compressed history %.2f MiB; five-to-ten-minute Lua memory growth %.2f MiB; distant seek %.3fs",
      compressedBytes / 1024 / 1024, (endMemory - halfwayMemory) / 1024, seekSeconds))
    seek(playback, 0)
    assert(match.engine.clock == 0, "Ten-minute replay could not rewind to the beginning")
    assert(tableUtils.length(playback.store.checkpoints) == 601,
      "Expected one compressed checkpoint per second plus frame zero")
  end)
end

withoutCheckpointFileIO(testCheckpointEncoding)
testCheckpointStoreCanBeGarbageCollected()
testReconstructionMatchesUninterruptedPlayback()
testFrameBoundariesAndPausedSeeking()
testContinuousRewindCrossesBufferBoundaries()
testSeekBudgetsAndSideEffects()
testModernPanelGeneratorAndSimulatedOpponent()
testReplaySceneControlsAndGameOver()
testTenMinuteReplayUsesCompressedHistory()
testClosingDuringReconstruction()
