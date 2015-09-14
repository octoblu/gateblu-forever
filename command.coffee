_ = require 'lodash'
fs = require 'fs-extra'
path = require 'path'
debug = require('debug')('gateblu:command')
colors = require 'colors'
Gateblu = require 'gateblu'
homedir = require 'homedir'
commander = require 'commander'
MeshbluHttp = require 'meshblu-http'
DeviceManager = require './index'
MeshbluConfig = require 'meshblu-config'

CONFIG_PATH = process.env.MESHBLU_JSON_FILE ? './meshblu.json'
OLD_CONFIG_PATH = "#{homedir()}/.config/gateblu/meshblu.json"
DEFAULT_OPTIONS =
  nodePath: process.env.GATEBLU_NODE_PATH ? ''
  devicePath: process.env.GATEBLU_DEVICE_PATH ? './devices'
  tmpPath: process.env.GATEBLU_TMP_PATH ? './tmp'
  server: process.env.GATEBLU_SERVER ? 'meshblu.octoblu.com'
  port: process.env.GATEBLU_PORT ? 443

class GatebluCommand
  getOptions: =>
    options = DEFAULT_OPTIONS
    if !fs.existsSync(CONFIG_PATH)
      if fs.existsSync(OLD_CONFIG_PATH)
        debug "using uuid and token from #{OLD_CONFIG_PATH}"
        oldOptions = require OLD_CONFIG_PATH
        options = _.extend options, uuid: oldOptions.uuid, token: oldOptions.token
      @saveOptions options
    meshbluConfig = new MeshbluConfig filename: CONFIG_PATH
    @parseOptions()
    options.skipInstall = @skipInstall
    _.defaults _.clone(meshbluConfig.toJSON()), options

  run: =>
    options = @getOptions()
    debug 'Starting Device Manager with options', options
    @deviceManager = new DeviceManager options
    return @start options if options.uuid
    @registerGateblu options, (error, newOptions) =>
      return console.error error if error?
      @writeMeshbluJSON newOptions, (error) =>
        return console.error error if error?
        @start newOptions

  writeMeshbluJSON: (options, callback=->)=>
    deviceConfig = _.clone options
    meshbluConfig = JSON.stringify deviceConfig, null, 2
    debug 'writing gateblu meshblu.json', deviceConfig
    fs.writeFile CONFIG_PATH, meshbluConfig, callback

  start: (options) =>
    debug 'starting gateblu'
    @gateblu = new Gateblu options, @deviceManager

    @deviceManager.on 'error', (error) =>
      @die error if error?

    @gateblu.on 'error', (error) =>
      @die error if error?

    process.on 'exit', (error) =>
      @die error if error?

    process.on 'SIGINT', =>
      debug 'SIGINT'
      process.stdin.resume()
      @deviceManager.shutdown =>
        process.exit 0

    process.on 'uncaughtException', (error) =>
      @die error

  parseOptions: =>
    commander
      .usage '[options]'
      .option '--skip-install', 'Skip npm install'
      .parse process.argv

    @skipInstall = commander.skipInstall ? (process.env.GATEBLU_SKIP_INSTALL?.toLocaleLowerCase() == 'true')

  die: (error) =>
    @deviceManager.shutdown =>
      if 'Error' == typeof error
        console.error colors.red error.message
        console.error error.stack
      else
        console.error colors.red arguments...
      process.exit 1

  saveOptions: (options) ->
    debug 'saveOptions', '\n', options
    fs.mkdirpSync path.dirname(CONFIG_PATH)
    fs.writeFileSync CONFIG_PATH, JSON.stringify(options, true, 2)

  registerGateblu: (options, callback=->) =>
    meshbluHttp = new MeshbluHttp options
    defaults =
      type: 'device:gateblu'
    properties = _.extend defaults, options
    debug 'registering gateblu', properties
    meshbluHttp.register properties, (error, device) =>
      debug 'registered gateblu', error
      return callback error if error?
      deviceProperties = _.omit device, ['geo', 'ipAddress', 'meshblu', 'online']
      callback null, deviceProperties

gatebluCommand = new GatebluCommand
gatebluCommand.run()
