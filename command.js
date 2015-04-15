var _             = require('lodash');
var fs            = require('fs');
var debug         = require('debug')('gateblu:command');
var Gateblu       = require('gateblu');
var DeviceManager = require('./index');

var CONFIG_PATH = './meshblu.json';
var DEFAULT_OPTIONS = {
  server:     process.env.MESHBLU_SERVER      || 'meshblu.octoblu.com',
  port:       process.env.MESHBLU_PORT        || '80',
  uuid:       process.env.MESHBLU_UUID,
  token:      process.env.MESHBLU_TOKEN,
  nodePath:   process.env.GATEBLU_NODE_PATH   || '',
  devicePath: process.env.GATEBLU_DEVICE_PATH || 'devices',
  tmpPath:    process.env.GATEBLU_TMP_PATH    || 'tmp'
};

var GatebluCommand = function(){
  var self, gateblu;
  self = this;

  self.getOptions = function(){
    if(!fs.existsSync(CONFIG_PATH)){
      self.saveOptions(DEFAULT_OPTIONS);
    }
    return _.defaults(_.clone(require(CONFIG_PATH)), DEFAULT_OPTIONS);
  };

  self.run = function(){
    var options = self.getOptions();
    var deviceManager = new DeviceManager({
      uuid: options.uuid,
      token: options.token,
      devicePath: options.devicePath,
      tmpPath: options.tmpPath,
      nodePath: options.nodePath,
      server:  options.server,
      port:    options.port
    });
    gateblu = new Gateblu(options, deviceManager);
    gateblu.on('gateblu:config', self.saveOptions);

    process.on('exit', function(error){
      if(error){
        console.error(error.message, error.stack);
      }
      debug('exit', error);
      gateblu.cleanup();
    });
    process.on('SIGINT', function(){
      debug('SIGINT');
      gateblu.cleanup();
    });
    process.on('uncaughtException', function(error){
      console.error(error.message, error.stack);
      debug('uncaughtException', error);
      gateblu.cleanup();
    });
  };

  self.saveOptions = function(options){
    debug("saveOptions", "\n", options);
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(options, true, 2));
  };
};

var gatebluCommand  = new GatebluCommand();
gatebluCommand.run();
