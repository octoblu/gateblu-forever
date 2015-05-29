'use strict'
_ = require 'lodash'
fs = require 'fs-extra'
debug = require('debug')('gateblu:command')
path = require 'path'
Gateblu = require 'gateblu'
DeviceManager = require './index'
CONFIG_PATH = process.env.MESHBLU_JSON_FILE or './meshblu.json'
homedir = require 'homedir'

OLD_CONFIG_PATH = "#{homedir()}/.config/gateblu/meshblu.json"
DEFAULT_OPTIONS =
  server: process.env.MESHBLU_SERVER or 'meshblu.octoblu.com'
  port: process.env.MESHBLU_PORT or 443
  uuid: process.env.MESHBLU_UUID
  token: process.env.MESHBLU_TOKEN
  nodePath: process.env.GATEBLU_NODE_PATH or ''
  devicePath: process.env.GATEBLU_DEVICE_PATH or 'devices'
  tmpPath: process.env.GATEBLU_TMP_PATH or 'tmp'

class GatebluCommand
  getOptions: =>
    options = DEFAULT_OPTIONS
    if !fs.existsSync(CONFIG_PATH)
      if fs.existsSync(OLD_CONFIG_PATH)
        debug "using uuid and token from #{OLD_CONFIG_PATH}"
        oldOptions = require OLD_CONFIG_PATH
        options = _.extend options, uuid: oldOptions.uuid, token: oldOptions.token
      @saveOptions options
    _.defaults _.clone(require(CONFIG_PATH)), options

  run: =>
    options = @getOptions()
    debug 'Starting Device Manager with options', options
    @deviceManager = new DeviceManager(options)
    @gateblu = new Gateblu(options, @deviceManager)
    @gateblu.on 'gateblu:config', @saveOptions
    process.on 'exit', (error) =>
      if error
        console.error error.message, error.stack
      debug 'exit', error
      @shutdownDeviceManager()

    process.on 'SIGINT', =>
      debug 'SIGINT'
      process.stdin.resume()
      @shutdownDeviceManager()

    process.on 'uncaughtException', (error) =>
      console.error error.message, error.stack
      debug 'uncaughtException', error
      @shutdownDeviceManager()

  shutdownDeviceManager: =>
    @deviceManager.shutdown =>
      process.exit 0

  saveOptions: (options) ->
    debug 'saveOptions', '\n', options
    fs.mkdirpSync path.dirname(CONFIG_PATH)
    fs.writeFileSync CONFIG_PATH, JSON.stringify(options, true, 2)

gatebluCommand = new GatebluCommand
gatebluCommand.run()
