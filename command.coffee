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
DEFAULT_OPTIONS =
  nodePath: process.env.GATEBLU_NODE_PATH ? ''
  devicePath: process.env.GATEBLU_DEVICE_PATH ? './devices'
  tmpPath: process.env.GATEBLU_TMP_PATH ? './tmp'
  server: process.env.GATEBLU_SERVER ? 'meshblu.octoblu.com'
  port: process.env.GATEBLU_PORT ? 443

class GatebluCommand
  parseOptions: =>
    commander
      .usage '[options]'
      .option '--skip-install', 'Skip npm install'
      .parse process.argv

    @skipInstall = commander.skipInstall ? (process.env.GATEBLU_SKIP_INSTALL?.toLocaleLowerCase() == 'true')

  getOptions: =>
    options = _.clone DEFAULT_OPTIONS
    options.skipInstall = @skipInstall
    return options unless fs.existsSync CONFIG_PATH

    try
      meshbluJSON = require CONFIG_PATH
      options = _.defaults meshbluJSON, options
    catch error
      @die 'Invalid Meshblu JSON'

    return options

  run: =>
    @parseOptions()
    @options = @getOptions()
    debug 'Starting Device Manager with options', @options
    return @updateAndStart() if @options.uuid and @options.token
    @registerGateblu (error) =>
      return console.error error if error?
      @saveOptions()
      @start()

  updateAndStart: =>
    meshbluHttp = new MeshbluHttp @options
    properties = {}
    properties.platform = process.platform
    meshbluHttp.update @options.uuid, properties, (error) =>
      return console.error error if error?
      @start()

  saveOptions: () ->
    debug 'saveOptions', @options
    fs.mkdirpSync path.dirname(CONFIG_PATH)
    fs.writeFileSync CONFIG_PATH, JSON.stringify(@options, true, 2)

  registerGateblu: (callback=->) =>
    meshbluHttp = new MeshbluHttp @options
    defaults =
      type: 'device:gateblu'
      platform: process.platform
    properties = _.extend defaults, @options
    debug 'registering gateblu', properties
    meshbluHttp.register properties, (error, device) =>
      debug 'registered gateblu', error
      return callback error if error?
      @options = _.omit device, ['geo', 'ipAddress', 'meshblu', 'online']
      callback null

  start: =>
    debug 'starting gateblu'
    @deviceManager = new DeviceManager @options
    @gateblu = new Gateblu @options, @deviceManager

    @deviceManager.once 'error', @die
    @gateblu.once 'error', @die
    process.once 'exit', @die

    process.once 'SIGINT', =>
      console.log colors.cyan '[SIGINT] Gracefully cleaning up...'
      process.stdin.resume()
      @deviceManager.shutdown =>
        process.exit 0

    process.once 'SIGTERM', =>
      console.log colors.cyan '[SIGTERM] Gracefully cleaning up...'
      process.stdin.resume()
      @deviceManager.shutdown =>
        process.exit 0

    process.once 'uncaughtException', (error) =>
      console.error 'Uncaught Exception'
      @die error

  die: (error) =>
    console.error colors.magenta 'Gateblu is now shutting down...'

    unless @deviceManager?
      @consoleError error
      process.exit 1

    @deviceManager.shutdown =>
      @consoleError error
      console.error colors.red 'Gateblu shutdown'
      process.exit 1

  consoleError: (error) =>
    if _.isError error
      console.error colors.red error.message
      console.error error.stack
    else
      console.error error

gatebluCommand = new GatebluCommand
gatebluCommand.run()
