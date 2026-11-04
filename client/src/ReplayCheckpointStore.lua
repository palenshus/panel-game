local class = require("common.lib.class")
local MessagePack = require("common.lib.jprof.MessagePack")

-- Preserve shared tables (notably currentChain), sparse numeric keys, and double precision.
---@param root table
---@return string
local function encode(root)
  local tables = {}
  local ids = {}
  local function reference(value)
    if type(value) ~= "table" then
      assert(type(value) == "string" or type(value) == "number" or type(value) == "boolean", "Invalid checkpoint value")
      return value
    end
    if not ids[value] then
      ids[value] = #tables + 1
      tables[#tables + 1] = value
    end
    return {ids[value]}
  end

  reference(root)
  local nodes = {}
  local index = 1
  while index <= #tables do
    local entries = {}
    for key, value in pairs(tables[index]) do
      entries[#entries + 1] = reference(key)
      entries[#entries + 1] = reference(value)
    end
    nodes[index] = entries
    index = index + 1
  end
  return love.data.compress("string", "lz4", MessagePack.pack(nodes))
end

---@param data string
---@return table
local function decode(data)
  local nodes = MessagePack.unpack(love.data.decompress("string", "lz4", data))
  local tables = {}
  for i = 1, #nodes do
    tables[i] = {}
  end
  local function dereference(value)
    if type(value) == "table" then
      return assert(tables[value[1]], "Invalid checkpoint reference")
    end
    return value
  end
  for i, entries in ipairs(nodes) do
    for j = 1, #entries, 2 do
      tables[i][dereference(entries[j])] = dereference(entries[j + 1])
    end
  end
  return assert(tables[1], "Empty replay checkpoint")
end

---@class ReplayCheckpointStore
---@field interval integer
---@field latestFrame integer
---@field checkpoints table<integer, string> Compressed checkpoints keyed by frame.
---@field compressedBytes integer Total size of the compressed checkpoint data.
---@field cachedFrame integer?
---@field cachedCheckpoint table? At most one decoded checkpoint is retained.
---@overload fun(interval: integer): ReplayCheckpointStore
local ReplayCheckpointStore = class(
---@param self ReplayCheckpointStore
---@param interval integer
function(self, interval)
  self.interval = interval
  self.latestFrame = -interval
  self.checkpoints = {}
  self.compressedBytes = 0
end)

---Retains compressed bytes rather than the captured object graph.
---@param frame integer
---@param checkpoint table
function ReplayCheckpointStore:save(frame, checkpoint)
  assert(frame == self.latestFrame + self.interval, "Replay checkpoints must be saved in order")
  local data = encode(checkpoint)
  self.checkpoints[frame] = data
  self.compressedBytes = self.compressedBytes + #data
  self.latestFrame = frame
end

---Decodes the closest checkpoint at or before frame, caching only one decoded object graph.
---@param frame integer
---@return table
function ReplayCheckpointStore:load(frame)
  local checkpointFrame = math.min(math.floor(frame / self.interval) * self.interval, self.latestFrame)
  assert(checkpointFrame >= 0, "Replay has no initial checkpoint")
  if checkpointFrame ~= self.cachedFrame then
    self.cachedCheckpoint = nil
    local data = assert(self.checkpoints[checkpointFrame], "Replay checkpoint is missing")
    self.cachedCheckpoint = decode(data)
    self.cachedFrame = checkpointFrame
  end
  return self.cachedCheckpoint
end

---Releases compressed history and the decoded checkpoint when playback ends.
function ReplayCheckpointStore:close()
  table.clear(self.checkpoints)
  self.compressedBytes = 0
  self.latestFrame = -self.interval
  self.cachedCheckpoint = nil
  self.cachedFrame = nil
end

return ReplayCheckpointStore
