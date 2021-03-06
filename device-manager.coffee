_ = require 'lodash'
fs = require 'fs'
url = require 'url'
path = require 'path'
util = require 'util'
async = require 'async'
rimraf = require 'rimraf'
forever = require 'forever-monitor'
packageJSON = require './package.json'
MeshbluHttp = require 'meshblu-http'
ProcessManager = require './process-manager'
{EventEmitter2} = require 'eventemitter2'
ConnectorManager = require './connector-manager'
debug = require('debug')('gateblu-forever:device-manager')

class DeviceManager extends EventEmitter2
  constructor: (@config, dependencies={}) ->
    @runningDevices = []
    @connectorsInstalled = {}
    @meshbluHttp = new MeshbluHttp @config
    {tmpPath} = @config
    @processManager = new ProcessManager {tmpPath}

  generateLogCallback : (callback=(->), workflow, device) =>
    debug workflow, uuid: device.uuid, name: device.name if device?
    debug workflow unless device?
    return (error) =>
      callback()

  addDevice: (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'add-device', device
    async.series [
      async.apply @stopDevice, device
      async.apply @installDeviceConnector, device
      async.apply @setupDevice, device
    ], callback

  removeDevice: (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'remove-device', device
    async.series [
      async.apply @stopDevice, device
    ], callback

  getConnectorPath: (device) =>
    return path.join @config.tmpPath, 'node_modules', device.connector

  spawnChildProcess: (device, _callback=->) =>
    debug 'spawning child process'
    @processManager.kill device, =>
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
        uid: device.uuid
        max: 1
        silent: true
        args: []
        env: environment
        cwd: connectorPath
        command: 'node'
        checkFile: false
        killTree: true

      child = new (forever.Monitor)('command.js', foreverOptions)
      child.on 'stderr', (data) =>
        debug 'stderr', device.uuid, data.toString()
        @emit 'stderr', data.toString(), device

      child.on 'stdout', (data) =>
        debug 'stdout', device.uuid, data.toString()
        @emit 'stdout', data.toString(), device

      child.on 'stop', =>
        debug "process for #{device.uuid} stopped."
        @processManager.clear device

      child.on 'exit', =>
        debug "process for #{device.uuid} stopped."
        @processManager.clear device

      child.on 'error', (error) =>
        debug 'error', error

      child.on 'exit:code', (code) =>
        debug 'exit:code', code

      debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
      child.start()
      @processManager.write device, _.get child, 'child.pid'
      callback null, child

  startDevice : (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'start-device', device
    @stopDevice device, (error) =>
      return callback error if error?

      debug 'startDevice', {name: device.name, uuid: device.uuid}
      @spawnChildProcess device, (error, child) =>
        return callback error if error?

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
    @processManager.killAll callback

  stopDevice: (device, _callback=->) =>
    callback = @generateLogCallback _callback, 'stop-device', device
    @processManager.kill device, callback

module.exports = DeviceManager
