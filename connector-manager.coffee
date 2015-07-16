_ = require 'lodash'
fs = require 'fs-extra'
cmp = require 'semver-compare'
npm = require 'npm'
path = require 'path'
debug = require('debug')('gateblu-forever:connector-manager')
request = require 'request'

class ConnectorManager
  constructor: (@installPath, @connector, dependencies={}) ->
    @connectorDir = path.join @installPath, 'node_modules', @connector

  install: (callback=->) =>
    debug 'install', @connector
    @isInstalled (installed) =>
      debug 'isInstalled', @connector, installed
      return @installConnector callback unless installed

      @isUpdateAvailable (updateAvailable) =>
        debug 'isUpdateAvailable', @connector, updateAvailable
        return updateConnector callback if updateAvailable
        callback()

  installConnector: (callback=->) =>
    npm.load production: true, =>
      debug 'installConnector', @connector, @installPath
      npm.commands.install @installPath, [@connector], (error) =>
        callback error

  updateConnector: (callback=->) =>
    npm.load production: true, =>
      debug 'updateConnector', @connector, @installPath
      npm.commands.update @installPath, [@connector], (error) =>
        callback error

  loadPackageJSON: (callback=->) =>
    packageFile = path.join @connectorDir, 'package.json'
    try
      callback null, JSON.parse fs.readFileSync packageFile
    catch e
      callback e

  isInstalled: (callback=->) =>
    @loadPackageJSON (error) =>
      callback !error

  isUpdateAvailable: (callback=->) =>
    @loadPackageJSON (error, packageJSON) =>
      request.get "https://registry.npmjs.org/#{@connector}", json: true, (error, response, body) =>
        callback false if error?
        callback cmp(body?['dist-tags']?.latest, packageJSON.version) > 0

module.exports = ConnectorManager
