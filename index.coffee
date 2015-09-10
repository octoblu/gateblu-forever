_ = require 'lodash'
fs = require 'fs-extra'
url = require 'url'
path = require 'path'
util = require 'util'
async = require 'async'
debug = require('debug')('gateblu-forever:device-manager')
{exec} = require 'child_process'
forever = require 'forever-monitor'
{EventEmitter2} = require 'eventemitter2'
MeshbluHttp = require 'meshblu-http'
ConnectorManager = require './connector-manager'
rimraf = require 'rimraf'
Uuid = require 'node-uuid'
packageJSON = require './package.json'

class DeviceManager extends EventEmitter2
  constructor: (@config, dependencies={}) ->
    @deviceProcesses = {}
    @runningDevices = []
    @connectorsInstalled = {}
    @deploymentUuids = {}
    @loggerUuid = process.env.GATEBLU_LOGGER_UUID || '4dd6d1a8-0d11-49aa-a9da-d2687e8f9caf'
    @meshbluHttp = new MeshbluHttp @config

  sendLogMessage: (workflow, state, device, error) =>
    @meshbluHttp.message
      devices: [ @loggerUuid, @config.uuid ]
      topic: 'gateblu_log'
      payload:
        application: 'gateblu-forever'
        deploymentUuid: @deploymentUuids[device?.uuid]
        gatebluUuid: @config?.uuid
        deviceUuid: device?.uuid
        connector: device?.connector
        state: state
        workflow: workflow
        message: error?.message
        platform: process.platform
        gatebluVersion: packageJSON.version

  generateLogCallback : (callback=(->), workflow, device) =>
    debug workflow, device?.uuid, device?.name
    @sendLogMessage workflow, 'begin', device
    return (error) =>
      if error?
        @sendLogMessage workflow, 'error', device, error
      else
        @sendLogMessage workflow, 'end', device
      callback error

  addDevice: (device, _callback=->) =>
    @deploymentUuids[device.uuid] = Uuid.v1()
    callback = @generateLogCallback _callback, 'add-device', device
    async.series [
      async.apply @stopDevice, device
      async.apply @installDeviceConnector, device
      async.apply @setupDevice, device
    ], callback

  removeDevice: (device, _callback=->) =>
    @deploymentUuids[device.uuid] = Uuid.v1()
    callback = @generateLogCallback _callback, 'remove-device', device
    async.series [
      async.apply @stopDevice, device
      async.apply @removeDeletedDeviceDirectory, device
    ], callback

  getDevicePath: (device) =>
    path.join @config.devicePath, device.uuid

  spawnChildProcess: (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'spawn-child-process', device
    devicePath = @getDevicePath device
    @writeMeshbluJSON devicePath, device, (error) =>
      return callback error if error?

      pathSep = ':'
      pathSep = ';' if process.platform == 'win32'

      env =
        'DEBUG' : process.env['DEBUG']

      foreverOptions =
        max: 1
        silent: true
        args: []
        env: env
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
        @sendLogMessage 'spawn-child-process', 'stderr', device, {message:data.toString()}

      child.on 'stdout', (data) =>
        debug 'stdout', device.uuid, data.toString()
        @emit 'stdout', data.toString(), device
        @sendLogMessage 'spawn-child-process', 'stdout', device, {message:data.toString()}

      child.on 'stop', =>
        debug "process for #{device.uuid} stopped."
        delete @deviceProcesses[device.uuid]
        @sendLogMessage 'spawn-child-process', 'stop', device

      child.on 'exit', =>
        debug "process for #{device.uuid} stopped."
        delete @deviceProcesses[device.uuid]
        @sendLogMessage 'spawn-child-process', 'exit', device

      child.on 'error', (err) =>
        debug 'error', err
        @sendLogMessage 'spawn-child-process', 'error', device, err

      child.on 'exit:code', (code) =>
        debug 'exit:code', code
        @sendLogMessage 'spawn-child-process', 'exit-code', device, {message:code}

      debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
      child.start()
      callback null, child

  startDevice : (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'start-device', device
    @stopDevice device, (error) =>
      return callback error if error?

      debug 'startDevice', {name: device.name, uuid: device.uuid}
      @spawnChildProcess device, (error, child) =>
        return callback error if error?

        @deviceProcesses[device.uuid] = child
        @emit 'start', device
        callback()

  installDeviceConnector : (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'install-connector', device
    return callback new Error('Invalid connector') if _.isEmpty device.connector
    connector = _.last device.connector?.split(':')

    if @connectorsInstalled[connector]
      debug "installDeviceConnector: #{connector} already installed this session. skipping."
      return callback()

    if @config.skipInstall
      debug 'skipping install', connector
      return callback()

    connectorManager = new ConnectorManager @config.tmpPath, connector
    connectorManager.install (error) =>
      if error?
        debug 'install error', 'doing rimraf on', @config.tmpPath, '/node_modules/', connector
        rimraf @config.tmpPath + '/node_modules/' + connector, (error) =>
          debug 'unable to delete tmpPath!', error
        return callback error
      debug 'connector installed', connector
      @connectorsInstalled[connector] = true
      callback()

  setupDevice: (device, _callback) =>
    callback = @generateLogCallback _callback, 'setup-device', device
    return callback new Error('Invalid connector') if _.isEmpty device.connector

    devicePath = @getDevicePath device
    connectorPath = path.join @config.tmpPath, 'node_modules', device.connector

    debug 'path', devicePath
    debug 'connectorPath', connectorPath
    debug 'copying files', devicePath

    fs.remove devicePath, (error) =>
      return callback error if error?

      fs.copy connectorPath, devicePath, (error) =>
        return callback error if error?

        debug 'done copying', devicePath
        callback()

  writeMeshbluJSON: (devicePath, device, _callback=->) =>
    callback = @generateLogCallback _callback, 'write-meshblu-json', device

    meshbluFilename = path.join devicePath, 'meshblu.json'
    deviceConfig = _.extend {},
      device,
      server: @config.server, port: @config.port

    deviceConfig = _.pick deviceConfig, 'uuid', 'token', 'server', 'port'
    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing meshblu.json', devicePath
    fs.writeFile meshbluFilename, meshbluConfig, callback

  shutdown: (_callback=->) =>
    callback = @generateLogCallback _callback, 'shutdown'
    async.eachSeries _.keys(@deviceProcesses), (uuid, callback) =>
      @stopDevice uuid: uuid, callback
    , callback

  stopDevice: (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'stop-device', device
    deviceProcess = @deviceProcesses[device.uuid]
    return callback null, device.uuid unless deviceProcess?

    if deviceProcess.running
      debug 'killing process for', device.uuid
      deviceProcess.killSignal = 'SIGINT'
      deviceProcess.stop()
      return callback null, device.uuid

    debug "process for #{device.uuid} wasn't running. Removing record."
    delete @deviceProcesses[device.uuid]
    callback null, device.uuid

  removeDeletedDeviceDirectory: (device, _callback) =>
    callback = @generateLogCallback _callback, 'remove-delete-device-directory', device
    devicePath = @getDevicePath device
    fs.exists devicePath, (exists) =>
      return callback() unless exists
      fs.remove devicePath, callback

module.exports = DeviceManager
