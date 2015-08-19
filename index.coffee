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

class DeviceManager extends EventEmitter2
  constructor: (@config, dependencies={}) ->
    @deviceProcesses = {}
    @runningDevices = []
    @connectorsInstalled = {}

  addDevice: (device, callback=->) =>
    debug 'addDevice', device.uuid
    async.series [
      async.apply @installConnector, device.connector
      async.apply @setupDevice, device
    ], callback

  removeDevice: (device, callback=->) =>
    debug 'removeDevice', device.uuid
    async.series [
      async.apply @stopDevice, device
      async.apply @removeDeletedDeviceDirectory, device
    ], callback

  getDevicePath: (device) =>
    path.join @config.devicePath, device.uuid

  spawnChildProcess: (device, callback=->) =>
    debug 'spawnChildProcess', {name: device.name, uuid: device.uuid}
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

      child.on 'stdout', (data) =>
        debug 'stdout', device.uuid, data.toString()
        @emit 'stdout', data.toString(), device

      child.on 'stop', =>
        debug "process for #{device.uuid} stopped."
        delete @deviceProcesses[device.uuid]

      debug 'forever', {uuid: device.uuid, name: device.name}, 'starting'
      child.start()
      callback null, child

  startDevice : (device, callback=->) =>
    @stopDevice device, (error) =>
      return callback error if error?

      debug 'startDevice', {name: device.name, uuid: device.uuid}
      @spawnChildProcess device, (error, child) =>
        return callback error if error?

        @deviceProcesses[device.uuid] = child
        @emit 'start', device
        callback()

  installConnector : (connector, callback=->) =>
    debug 'installConnector', connector
    return callback new Error('Invalid connector') if _.isEmpty connector

    connector = _.last connector?.split(':')

    if @connectorsInstalled[connector]
      debug "installConnector: #{connector} already installed this session. skipping."
      return callback()

    if @config.skipInstall
      debug 'skipping install', connector
      return callback()

    connectorManager = new ConnectorManager @config.tmpPath, connector
    connectorManager.install (error) =>
      return callback error if error?
      debug 'connector installed', connector
      @connectorsInstalled[connector] = true
      callback()

  setupDevice: (device, callback) =>
    debug 'setupDevice', uuid: device.uuid, name: device.name
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

  writeMeshbluJSON: (devicePath, device, callback=->) =>
    meshbluFilename = path.join devicePath, 'meshblu.json'
    deviceConfig = _.extend {},
      device,
      server: @config.server, port: @config.port

    deviceConfig = _.pick deviceConfig, 'uuid', 'token', 'server', 'port'
    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing meshblu.json', devicePath
    fs.writeFile meshbluFilename, meshbluConfig, callback

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
      return callback null, device.uuid

    debug "process for #{device.uuid} wasn't running. Removing record."
    delete @deviceProcesses[device.uuid]
    callback null, device.uuid

  removeDeletedDeviceDirectory: (device, callback) =>
    devicePath = @getDevicePath device
    fs.exists devicePath, (exists) =>
      return callback() unless exists
      fs.remove devicePath, callback

module.exports = DeviceManager
