util = require 'util'
{EventEmitter} = require 'events'
fs = require 'fs-extra'
path = require 'path'
forever = require 'forever-monitor'
{exec} = require 'child_process'
_ = require 'lodash'
async = require 'async'
debug = require('debug')('gateblu:deviceManager')
url = require 'url'
MeshbluHttp = require 'meshblu-http'

class DeviceManager extends EventEmitter
  constructor: (@config, dependencies={}) ->
    @deviceProcesses = {}
    @runningDevices = []
    @connectorsInstalled = {}

  addDevice: (device, callback=->) =>
    debug 'addDevice', device
    async.series [
      (callback) => @installConnector device.connector, callback
      (callback) => @setupDevice device, callback
      (callback) => @startDevice device, callback
    ], callback

  removeDevice: (device, callback=->) =>
    debug 'removeDevice', device
    async.series [
      (callback) => @stopDevice device, callback
      (callback) => @removeDeletedDeviceDirectory device, callback
    ], callback

  # refreshDevices: (devices, callback) =>
  #   debug 'refreshDevices', _.pluck(devices, 'uuid')
  #
  #   @getDevicesByOperation devices, ( devicesToStart
  #                                     devicesToStop
  #                                     devicesToRestart
  #                                     devicesToDelete
  #                                     unchangedDevices) =>
  #     connectorsToInstall = _.compact _.uniq _.pluck devicesToStart, 'connector'
  #     debug "connectorsToInstall", connectorsToInstall
  #     async.series(
  #       [
  #         (callback) => async.each connectorsToInstall, @installConnector, callback
  #         (callback) => async.each devicesToStop, @stopDevice, callback
  #         (callback) => async.each devicesToDelete, @stopDevice, callback
  #         (callback) => async.each devicesToDelete, @removeDeletedDeviceDirectory, callback
  #         (callback) => async.each devicesToStart, @setupDevice, callback
  #         (callback) => async.each devicesToStart, @startDevice, callback
  #         (callback) => async.each devicesToRestart, @restartDevice, callback
  #       ]
  #       (error, result)=>
  #         @runningDevices = _.union devicesToStart, devicesToRestart, unchangedDevices
  #         @emit 'update', _.union(devicesToStart, devicesToRestart, devicesToStop, unchangedDevices)
  #         callback error, result
  #     )
  #
  # getDevicesByOperation: (newDevices=[], callback=->) =>
  #   oldDevices = _.clone @runningDevices
  #   devicesToProcess = _.clone newDevices
  #   debug 'getDevicesByOperation', oldDevices, devicesToProcess
  #   async.filterSeries devicesToProcess, @deviceExistsAsync, (remainingDevices) =>
  #     debug 'remainingDevices', remainingDevices
  #     remainingDevices = _.compact remainingDevices
  #     debug 'oldDevices', _.pluck(oldDevices, 'name')
  #     debug 'newDevices', _.pluck(remainingDevices, 'name')
  #
  #     devicesToDelete = _.filter oldDevices, (device) =>
  #       ! _.findWhere remainingDevices, uuid: device.uuid
  #
  #     debug 'devicesToDelete:', _.pluck(devicesToDelete, 'name')
  #     remainingDevices = _.difference remainingDevices, devicesToDelete
  #
  #     devicesToStop = _.filter remainingDevices, stop: true
  #     debug 'devicesToStop:', _.pluck(devicesToStop, 'name')
  #
  #     remainingDevices = _.difference remainingDevices, devicesToStop
  #
  #     devicesToStart = _.filter remainingDevices, (device) =>
  #       ! _.findWhere oldDevices, uuid: device.uuid
  #
  #     debug 'devicesToStart:', _.pluck(devicesToStart, 'name')
  #
  #     remainingDevices = _.difference remainingDevices, devicesToStart
  #
  #     devicesToRestart = _.filter remainingDevices, (device) =>
  #       deviceToRestart = _.findWhere oldDevices, uuid: device.uuid
  #       return device.token != deviceToRestart?.token
  #
  #     debug 'devicesToRestart:', _.pluck(devicesToRestart, 'name')
  #
  #     unchangedDevices = _.difference remainingDevices, devicesToRestart
  #     debug 'unchangedDevices', _.pluck(unchangedDevices, 'name')
  #
  #     callback devicesToStart, devicesToStop, devicesToRestart, devicesToDelete, unchangedDevices
  #
  # deviceExistsAsync: (device, callback=->) =>
  #   @deviceExists device, (error, deviceResponse) =>
  #     debug 'deviceExistsAsync', error, deviceResponse
  #     return callback false if error?
  #     return callback false unless deviceResponse?
  #     callback true
  #
  # deviceExists: (device, callback=->) =>
  #   debug 'deviceExists', device.uuid
  #
  #   auth =
  #     uuid: device.uuid
  #     token: device.token
  #
  #   httpConfig = _.extend {}, @config, auth
  #   meshbluHttp = new MeshbluHttp httpConfig
  #   meshbluHttp.device device.uuid, (error, meshbluDevice) =>
  #     debug 'meshbluHttp response', error, meshbluDevice
  #     return callback error if error?
  #     device = _.extend {}, meshbluDevice, device
  #     debug 'device exists', device.uuid, device.name
  #     callback null, device

  getDevicePath: (device) =>
    path.join @config.devicePath, device.uuid

  startDevice : (device, callback=->) =>
    debug 'startDevice', { name: device.name, uuid: device.uuid}
    devicePath = @getDevicePath device
    @writeMeshbluJSON devicePath, device

    pathSep = ':'
    pathSep = ';' if process.platform == 'win32'

    foreverOptions =
      max: 1
      silent: true
      options: []
      cwd: devicePath
      logFile: path.join devicePath, 'forever.log'
      outFile: path.join devicePath, 'forever.stdout'
      errFile: path.join devicePath, 'forever.stderr'
      command: 'node'
      checkFile: false

    child = new (forever.Monitor)('command.js', foreverOptions)
    child.on 'stderr', (data) =>
      debug 'stderr', device.uuid, data.toString()
      @emit 'stderr', data.toString(), device

    child.on 'stdout', (data) =>
      debug 'stdout', device.uuid, data.toString()
      @emit 'stdout', data.toString(), device

    child.on 'stop', =>
      debug "process for #{device.uuid} stopped."
      delete @deviceProcesses[device.uuid]

    debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
    child.start()
    @deviceProcesses[device.uuid] = child
    @emit 'start', device
    callback()

  installConnector : (connector, callback=->) =>
    debug 'installConnector', connector
    if _.isEmpty(connector)
      return callback()

    connector = _.last connector.split(':')

    if @connectorsInstalled[connector]
      debug "installConnector: #{connector} already installed this session. skipping."
      return callback()

    nodeModulesDir = path.join @config.tmpPath, 'node_modules'
    fs.mkdirpSync @config.tmpPath unless fs.existsSync @config.tmpPath
    connectorPath = path.join nodeModulesDir, connector
    npmMethod = "install"
    npmMethod = "update" if fs.existsSync "#{connectorPath}/package.json"
    prefix = ''
    prefix = 'cmd.exe /c ' if process.platform == 'win32'
    npm_command = "#{prefix} npm --prefix=. #{npmMethod} #{connector}"
    debug "npm install: #{npm_command}, cwd: #{@config.tmpPath}"
    exec(npm_command,
      cwd: @config.tmpPath
      (error, stdout, stderr) =>
        if error?
          debug 'npm install error:', error
          console.error error
          @emit 'stderr', error
          return callback()

        if stderr?
          @emit 'npm:stderr', stderr.toString()
          debug 'npm:stderr', stderr.toString()

        if stdout?
          @emit 'npm:stdout', stdout.toString()
          debug 'npm:stdout', stdout.toString()

        debug 'connector installed', connector
        @connectorsInstalled[connector] = true
        callback()
    )

  setupDevice: (device, callback) =>
    debug 'setupDevice', {uuid: device.uuid, name: device.name}

    devicePath = @getDevicePath device
    connectorPath = path.join @config.tmpPath, 'node_modules', device.connector

    debug 'path', devicePath
    debug 'connectorPath', connectorPath

    try
      debug 'copying files', devicePath
      fs.removeSync devicePath
      fs.copySync connectorPath, devicePath
      _.defer -> callback()

    catch error
      console.error error
      @emit 'stderr', error
      debug 'forever error:', error
      _.defer -> callback()

  writeMeshbluJSON: (devicePath, device) =>
    meshbluFilename = path.join devicePath, 'meshblu.json'
    deviceConfig = _.extend {},
      device,
      server: @config.server, port: @config.port

    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing meshblu.json', devicePath
    fs.writeFileSync meshbluFilename, meshbluConfig

  restartDevice: (device, callback) =>
    debug 'restartDevice', {uuid: device.uuid, name: device.name}
    @stopDevice device, (error) =>
      debug 'restartDevice error:', error if error?
      @startDevice device, callback

  shutdown: (callback=->) =>
    async.eachSeries _.keys(@deviceProcesses), (uuid, callback) =>
      @stopDevice uuid: uuid, callback
    , callback

  stopDevice: (device, callback=->) =>
    debug 'stopDevice', device.uuid
    deviceProcess = @deviceProcesses[device.uuid]
    return callback null, device.uuid unless deviceProcess?

    if deviceProcess.running
      debug 'killing process for', device.uuid
      deviceProcess.killSignal = 'SIGINT'
      deviceProcess.stop()
      callback null, device.uuid

    debug "process for #{device.uuid} wasn't running. Removing record."
    delete @deviceProcesses[device.uuid]
    callback null, device.uuid

  removeDeletedDeviceDirectory: (device, callback) =>
    fs.remove @getDevicePath(device), (error) =>
      console.error error if error?
      callback()

module.exports = DeviceManager
