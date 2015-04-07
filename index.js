var util = require('util');
var EventEmitter = require('events').EventEmitter;
var fs = require('fs-extra');
var path = require('path');
var rimraf = require('rimraf');
var forever = require('forever-monitor');
var exec = require('child_process').exec;
var _ = require('lodash');
var async = require('async');
var request = require('request');
var debug     = require('debug')('gateblu:deviceManager');

var DeviceManager = function (config) {
  var self = this;
  var deviceProcesses = {};
  var runningDevices = [];
  self.refreshDevices = function (devices, callback) {
    debug('refreshDevices', _.pluck(devices, 'uuid'));
    callback = callback || _.noop;

    async.map(devices || [], self.deviceExists, function (error, devices) {
      if (error) {
        console.error(error, 'Error verifying devices. Refusing to be useful');
        return callback(error);
      }

      devices = _.compact(devices);

      debug('devices:', devices);
      debug('runningDevices:', runningDevices);

      var devicesToStop = _.reject(runningDevices, function(device){
        return _.findWhere(devices, {uuid: device.uuid, token: device.token});
      });

      debug('devicesToStop:', devicesToStop);

      var devicesToStart = _.reject(devices, function(device){
        return _.findWhere(runningDevices, {uuid: device.uuid, token: device.token});
      });

      debug('devicesToStart:', devicesToStart);

      runningDevices = devices;

      async.each( _.pluck(devicesToStop, 'uuid'), self.stopDevice, function(error){
        self.emit('update', devices);
        self.installDevices(devicesToStart, callback);
      });

    });
  };

  self.deviceExists = function (device, callback) {
    callback = callback || _.noop;
    var authHeaders, deviceUrl;
    if (!device.connector) {
      _.defer(callback);
      return;
    }

    authHeaders = {skynet_auth_uuid: device.uuid, skynet_auth_token: device.token};
    deviceUrl = 'http://' + config.server + ':' + config.port + '/devices/' + device.uuid;
    debug('requesting device', deviceUrl);
    request({url: deviceUrl, headers: authHeaders, json: true}, function (error, response, body) {
      if (error || response.statusCode !== 200) {
        return callback(error, null);
      }
      debug('device exists', deviceUrl);
      callback(null, _.extend(body.devices[0], device));
    });
  };

  self.installDevices = function (devices, callback) {
    callback = callback || _.noop;
    debug('installDevices', _.pluck(devices, 'uuid'));
    var connectors = _.compact(_.uniq(_.pluck(devices, 'connector')));

    async.series([
      function (callback) {
        self.installConnectors(connectors, callback);
      },
      function (callback) {
        fs.mkdirp(config.devicePath, callback);
      },
      function (callback) {
        async.eachSeries(devices, self.setupAndStartDevice, callback);
      }
    ], callback);
  };

  self.installConnectors = function (connectors, callback) {
    callback = callback || _.noop;
    debug('installConnectors', connectors);
    async.series([
      function (callback) {
        fs.mkdirp(path.join(config.tmpPath, 'node_modules'), callback);
      },
      function (callback) {
        async.eachSeries(connectors, self.installConnector, callback);
      }
    ], callback);
  };

  self.installConnector = function (connector, callback) {
    var cachePath, connectorPath, npmCommand, cmd, prefix;
    callback = callback || _.noop;
    debug('installConnector', connector);

    cachePath = config.tmpPath;
    connectorPath = path.join(cachePath, 'node_modules', connector);
    npmCommand = 'install';
    if (fs.existsSync(connectorPath)) {
      npmCommand = 'update';
    }

    if (process.platform === 'win32') {
      prefix = 'cmd.exe /c ';
    } else {
      prefix = '';
    }

    cmd = prefix + 'npm --prefix=. ' + npmCommand + ' ' + connector;
    debug('executing cmd', cmd);

    exec(cmd, {cwd: cachePath}, function(error, stdout, stderr){
      if (error) {
        console.error(error);
        self.emit('stderr', error);
        debug('forever error:', error);
        callback();
        return;
      }

      self.emit('npm:stderr', stderr.toString());
      self.emit('npm:stdout', stdout.toString());
      debug('forever stdout', stdout.toString());
      debug('forever stderr', stderr.toString());
      callback();
    });
  };

  self.setupAndStartDevice = function (device, callback) {
    callback = callback || _.noop;
    debug('setupAndStartDevice', device.uuid);
    async.series([
      function (callback) {
        self.setupDevice(device, callback);
      },
      function (callback) {
        self.startDevice(device, callback);
      },
    ], callback);
  };

  self.setupDevice = function (device, callback) {
    callback = callback || _.noop;
    debug('setupDevice', device.uuid, device.token);
    debug('path', config.devicePath, device.uuid);
    var connectorPath, deviceConfig, devicePath, cachePath, meshbluConfig, meshbluFilename;
    try {
      devicePath = path.join(config.devicePath, device.uuid);
      deviceConfig = _.extend({}, device, {server: config.server, port: config.port});
      cachePath = config.tmpPath;
      connectorPath = path.join(cachePath, 'node_modules', device.connector);
      meshbluFilename = path.join(devicePath, 'meshblu.json');
      meshbluConfig = JSON.stringify(deviceConfig, null, 2);
      debug('copying files', devicePath);
      rimraf.sync(devicePath);
      fs.copySync(connectorPath, devicePath);
      fs.writeFileSync(meshbluFilename, meshbluConfig);

      _.defer(function () {
        callback();
      });
    } catch (error) {
      if (error) {
        console.error(error);
        self.emit('stderr', error);
        debug('forever error:', error);
      }
      _.defer(function () {
        callback();
      });
    }
  };

  self.startDevice = function (device, callback) {
    var devicePath, child, pathSep;
    callback = callback || _.noop;
    debug('startDevice', device.uuid);

    devicePath = path.join(config.devicePath, device.uuid);
    if (process.platform === 'win32') {
      pathSep = ';';
    } else {
      pathSep = ':';
    }

    var foreverOptions = {
      max: 1,
      silent: true,
      options: [],
      cwd: devicePath,
      logFile: devicePath + '/forever.log',
      outFile: devicePath + '/forever.stdout',
      errFile: devicePath + '/forever.stderr',
      command: 'node',
      checkFile: false
    };

    child = new (forever.Monitor)('command.js', foreverOptions);

    child.on('stderr', function(data) {
      debug('stderr', device.uuid, data.toString());
      self.emit('stderr', data.toString(), device);
    });

    child.on('stdout', function(data) {
      debug('stdout', device.uuid, data.toString());
      self.emit('stdout', data.toString(), device);
    });

    debug('forever', device.uuid, 'starting');
    child.start();
    deviceProcesses[device.uuid] = child;

    self.emit('start', device);
    callback();
  };

  self.stopDevice = function (uuid, callback) {
    var deviceProcess = deviceProcesses[uuid];
    callback = callback || _.noop;
    debug('stopDevice', uuid);

    if (!deviceProcess) {
      debug('couldn\'t find device process');
      return callback(null, uuid);
    }

    deviceProcess.on('stop', function() {
      debug('process for ' + uuid + ' stopped.');
      delete deviceProcesses[uuid];
      callback(null, uuid);
    });

    if (deviceProcess.running){
      debug('killing process for '+ uuid);
      deviceProcess.killSignal = 'SIGINT';
      deviceProcess.kill();
    } else {
      debug('process for ' + uuid + ' wasn\'t running. Removing record.');
      delete deviceProcesses[uuid];
      callback(null, uuid);
    }
  };

  self.stopDevices = function(callback) {
    callback = callback || _.noop;
    debug('stopDevices');
    async.each( _.keys(deviceProcesses), self.stopDevice, callback );
  };
};

util.inherits(DeviceManager, EventEmitter);
module.exports = DeviceManager;
