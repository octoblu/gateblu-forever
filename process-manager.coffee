fs      = require 'fs-extra'
path    = require 'path'
async   = require 'async'
forever = require 'forever-monitor'
debug   = require('debug')('gateblu-forever:process-manager')

PIDS_DIR='pids'

class ProcessManager
  constructor: ({@tmpPath}) ->
    fs.mkdirsSync @getPath()

  getPath: (device) =>
    return path.join @tmpPath, PIDS_DIR, device.uuid if device?
    path.join @tmpPath, PIDS_DIR

  exists: (device) =>
    fs.existsSync @getPath device

  get: (device) =>
    pid = fs.readFileSync(@getPath device).toString() if @exists device
    debug 'got pid', {pid: pid, uuid: device.uuid}
    return unless pid?
    pid = parseInt pid
    return pid

  write: (device, pid) =>
    debug 'writing process file', uuid: device.uuid, pid: pid
    return unless pid?
    fs.writeFileSync @getPath(device), pid

  clear: (device) =>
    filePath = @getPath device
    debug 'clearing process file', uuid: device.uuid, filePath:filePath
    fs.unlinkSync filePath if @exists device
    debug 'cleared process file', !@exists device

  isRunning: (device) =>
    debug 'check is running'
    pid = @get device
    unless pid?
      return false
    running = forever.checkProcess pid
    debug 'process is running', running
    return running

  getAllProcesses: (callback) =>
    items = []
    fs.walk @getPath()
      .on 'data', (item) =>
        uuid = path.basename item.path
        debug 'got item search for process', uuid: uuid
        return unless uuid?
        return if uuid == PIDS_DIR
        items.push
          uuid: uuid
      .on 'end', =>
        debug 'got all processes', items
        callback null, items

  kill: (device, callback) =>
    running = @isRunning device
    debug 'maybe killing process', uuid:device.uuid, running:running
    return callback null unless running
    debug 'killing process', uuid: device.uuid
    forever.kill @get(device), true, 'SIGINT', =>
      @clear device
      debug 'killed process', uuid: device.uuid
      callback()

  killAll: (callback) =>
    @getAllProcesses (error, devices) =>
      async.eachSeries devices, @kill, callback

module.exports = ProcessManager
