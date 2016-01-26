_ = require 'lodash'
url = require 'url'
path = require 'path'
util = require 'util'
Uuid = require 'node-uuid'
async = require 'async'
debug = require('debug')('gateblu-forever:device-manager')
rimraf = require 'rimraf'
{exec} = require 'child_process'
forever = require 'forever-monitor'
packageJSON = require './package.json'
MeshbluHttp = require 'meshblu-http'
{EventEmitter2} = require 'eventemitter2'
ConnectorManager = require './connector-manager'

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
    , (error) =>
      console.error error.stack

  generateLogCallback : (callback=(->), workflow, device) =>
    debug workflow, uuid: device?.uuid, name: device?.name
    @sendLogMessage workflow, 'begin', device
    return (error) =>
      if error?
        @sendLogMessage workflow, 'error', device, error
      else
        @sendLogMessage workflow, 'end', device
      callback()

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
    ], callback

  getConnectorPath: (device) =>
    return path.join @config.tmpPath, 'node_modules', device.connector

  spawnChildProcess: (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'spawn-child-process', device
    connectorPath = @getConnectorPath device
    debugEnv = device?.env?.DEBUG
    debugEnv ?= process.env.DEBUG
    environment =
      DEBUG: debugEnv
      MESHBLU_UUID: device.uuid
      MESHBLU_TOKEN: device.token
      MESHBLU_SERVER: @config.server
      MESHBLU_PORT: @config.port
    foreverOptions =
      max: 1
      silent: true
      args: []
      env: environment
      cwd: connectorPath
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
        connectorPath = @getConnectorPath device
        debug 'install error', 'doing rimraf on', connectorPath
        rimraf connectorPath, (error) =>
          debug 'unable to delete tmpPath!', error if error
        return callback error
      debug 'connector installed', connector
      @connectorsInstalled[connector] = true
      callback()

  setupDevice: (device, _callback) =>
    callback = @generateLogCallback _callback, 'setup-device', device
    return callback new Error('Invalid connector') if _.isEmpty device.connector
    callback()

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

module.exports = DeviceManager
