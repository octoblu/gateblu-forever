util = require('util')
{EventEmitter} = require('events')
fs = require('fs-extra')
path = require('path')
forever = require('forever-monitor')
exec = require('child_process').exec
_ = require('lodash')
async = require('async')
request = require('request')
debug = require('debug')('gateblu:deviceManager')

class DeviceManager extends EventEmitter
  constructor: (@config) ->
    @deviceProcesses = {}
    @runningDevices = []
    @connectorsInstalled = {}

  refreshDevices: (devices, callback) =>
    debug 'refreshDevices', _.pluck(devices, 'uuid')

    @getDevicesByOperation devices, ( devicesToStart
                                      devicesToStop
                                      devicesToRestart
                                      devicesToDelete
                                      unchangedDevices) =>
      connectorsToInstall = _.uniq _.pluck devicesToStart, 'connector'

      async.series(
        [
          (callback) => async.each connectorsToInstall, @installConnector, callback
          (callback) => async.each devicesToStop, @stopDevice, callback
          (callback) => async.each devicesToDelete, @stopDevice, callback
          (callback) => async.each devicesToDelete, @removeDeletedDeviceDirectory, callback
          (callback) => async.each devicesToStart, @setupDevice, callback
          (callback) => async.each devicesToStart, @startDevice, callback
          (callback) => async.each devicesToRestart, @restartDevice, callback
        ]
        (error, result)=>
          @runningDevices = _.union devicesToStart, devicesToRestart, unchangedDevices
          @emit 'update', _.union(devicesToStart, devicesToRestart, devicesToStop, unchangedDevices)
          callback error, result
      )

  getDevicesByOperation: (newDevices=[], callback=->) =>
    oldDevices = _.clone @runningDevices
    devicesToProcess = _.clone newDevices
    debug 'newDevices length', newDevices.length
    debug 'getDevicesByOperation'
    async.map devicesToProcess, @deviceExists, (error, remainingDevices) =>
      return callback error if error?

      remainingDevices = _.compact remainingDevices
      debug 'oldDevices', _.pluck(oldDevices, 'name')
      debug 'newDevices', _.pluck(remainingDevices, 'name')

      devicesToDelete = _.filter oldDevices, (device) =>
        ! _.findWhere remainingDevices, uuid: device.uuid

      debug 'devicesToDelete:', _.pluck(devicesToDelete, 'name')
      remainingDevices = _.difference remainingDevices, devicesToDelete

      devicesToStop = _.filter remainingDevices, stop: true
      debug 'devicesToStop:', _.pluck(devicesToStop, 'name')

      remainingDevices = _.difference remainingDevices, devicesToStop

      devicesToStart = _.filter remainingDevices, (device) =>
        ! _.findWhere oldDevices, uuid: device.uuid

      debug 'devicesToStart:', _.pluck(devicesToStart, 'name')

      remainingDevices = _.difference remainingDevices, devicesToStart

      devicesToRestart = _.filter remainingDevices, (device) =>
        deviceToRestart = _.findWhere oldDevices, uuid: device.uuid
        return device.token != deviceToRestart?.token

      debug 'devicesToRestart:', _.pluck(devicesToRestart, 'name')

      unchangedDevices = _.difference remainingDevices, devicesToRestart
      debug 'unchangedDevices', _.pluck(unchangedDevices, 'name')

      callback devicesToStart, devicesToStop, devicesToRestart, devicesToDelete, unchangedDevices

  deviceExists: (device, callback=->) =>
    debug 'deviceExists', device.uuid

    authHeaders =
      skynet_auth_uuid: device.uuid
      skynet_auth_token: device.token
    deviceUrl = "http://#{@config.server}:#{@config.port}/devices/#{device.uuid}"
    debug 'requesting device', deviceUrl, 'auth:', authHeaders

    request url: deviceUrl, headers: authHeaders, json: true, (error, response, body) =>
      return callback(error, null) if error? || body.error?
      device = _.extend {}, body.devices[0], device
      debug 'device exists', device.name
      callback null, device

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
      dataJSON = JSON.stringify data, null, 2
      debug 'stderr', device.uuid, dataJSON
      @emit 'stderr', dataJSON, device

    child.on 'stdout', (data) =>
      dataJSON = JSON.stringify data, null, 2
      debug 'stdout', device.uuid, dataJSON
      @emit 'stdout', dataJSON, device

    debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
    child.start()
    @deviceProcesses[device.uuid] = child
    @emit 'start', device
    callback()

  installConnector : (connector, callback=->) =>
    debug 'installConnector', connector
    if @connectorsInstalled[connector]
      debug "installConnector: #{connector} already installed this session. skipping."
      return callback()

    nodeModulesDir = path.join @config.tmpPath, 'node_modules'
    connectorPath = path.join nodeModulesDir, connector
    fs.mkdirpSync connectorPath
    prefix = ''
    prefix = 'cmd.exe /c ' if process.platform == 'win32'
    npmMethod = "install"
    npmMethod = "update" if fs.existsSync connectorPath
    exec("#{prefix} npm --prefix=. #{npmMethod} #{connector}"
      cwd: @config.tmpPath
      (error, stdout, stderr) =>
        if error?
          debug 'forever error:', error
          console.error error
          @emit 'stderr', error
          return callback()

        @emit 'npm:stderr', stderr
        @emit 'npm:stdout', stdout
        debug 'npm:stdout', stdout
        debug 'npm:stderr', stderr
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
      _.defer => callback()

    catch error
      console.error error
      @emit 'stderr', error
      debug 'forever error:', error
      _.defer => callback()

  writeMeshbluJSON: (devicePath, device) =>
    meshbluFilename = path.join(devicePath, 'meshblu.json')
    deviceConfig = _.extend {}, device, {server: @config.server, port: @config.port}
    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing meshblu.json', devicePath
    fs.writeFileSync meshbluFilename, meshbluConfig

  restartDevice: (device, callback) =>
    debug 'restartDevice', {uuid: device.uuid, name: device.name}
    @stopDevice device, (error) =>
      debug 'restartDevice error:', error if error?
      @startDevice device, callback

  stopDevice: (device, callback=->) =>
    debug 'stopDevice', device.uuid
    deviceProcess = @deviceProcesses[device.uuid]
    return callback null, device.uuid unless deviceProcess?

    deviceProcess.on 'stop', =>
      debug "process for #{device.uuid} stopped."
      delete @deviceProcesses[device.uuid]
      callback null, device

    if deviceProcess.running
      debug 'killing process for', device.uuid
      deviceProcess.killSignal = 'SIGINT'
      deviceProcess.kill()
      return

    debug 'process for ' + uuid + ' wasn\'t running. Removing record.'
    delete @deviceProcesses[uuid]
    callback null, uuid

  removeDeletedDeviceDirectory: (device, callback) =>
    fs.remove @getDevicePath(device), (error) =>
      console.error error if error?
      callback()

  stopDevices: (callback=->) =>
    async.each @runningDevices, @stopDevice, callback

module.exports = DeviceManager
