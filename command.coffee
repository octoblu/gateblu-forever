_ = require 'lodash'
fs = require 'fs-extra'
path = require 'path'
debug = require('debug')('gateblu:command')
colors = require 'colors'
Gateblu = require 'gateblu'
homedir = require 'homedir'
commander = require 'commander'
DeviceManager = require './index'
MeshbluConfig = require 'meshblu-config'

CONFIG_PATH = process.env.MESHBLU_JSON_FILE ? './meshblu.json'
OLD_CONFIG_PATH = "#{homedir()}/.config/gateblu/meshblu.json"
DEFAULT_OPTIONS =
  nodePath: process.env.GATEBLU_NODE_PATH ? ''
  devicePath: process.env.GATEBLU_DEVICE_PATH ? './devices'
  tmpPath: process.env.GATEBLU_TMP_PATH ? './tmp'

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
    _.defaults _.clone(meshbluConfig.toJSON()), options

  run: =>
    options = @getOptions()
    @parseOptions()
    options = _.extend {}, @getOptions(), skipInstall: @skipInstall
    debug 'Starting Device Manager with options', options
    @deviceManager = new DeviceManager options
    @gateblu = new Gateblu options, @deviceManager
    process.on 'exit', (error) =>
      @die error if error?

    process.on 'SIGINT', =>
      debug 'SIGINT'
      process.stdin.resume()
      @deviceManager.shutdown =>
        process.exit 0

    process.on 'uncaughtException', (error) =>
      debug 'uncaughtException', error
      @die error

  parseOptions: =>
    commander
      .usage '[options]'
      .option '--skip-install', 'Skip npm install'
      .parse process.argv

    @skipInstall = commander.skipInstall

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

gatebluCommand = new GatebluCommand
gatebluCommand.run()
