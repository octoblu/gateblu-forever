var fs            = require('fs');
var debug         = require('debug')('gateblu:command');
var Gateblu       = require('gateblu');
var DeviceManager = require('./index');

var CONFIG_PATH = './meshblu.json';
var DEFAULT_OPTIONS = {
  server:     'meshblu.octoblu.com',
  port:       '80',
  nodePath:   '',
  devicePath: 'devices',
  tmpPath:    'tmp'
};

var GatebluCommand = function(){
  var self, gateblu;
  self = this;

  self.getOptions = function(){
    if(!fs.existsSync(CONFIG_PATH)){
      self.saveOptions(DEFAULT_OPTIONS);
    }
    return require(CONFIG_PATH);
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

    process.on('exit',              function(error){
      console.error(error.message, error.stack);
      debug('exit', error);
      gateblu.cleanup();
    });
    process.on('SIGINT', function(error){
      console.error(error.message, error.stack);
      debug('SIGINT', error);
      gateblu.cleanup();
    });
    process.on('uncaughtException', function(error){
      console.error(error.message, error.stack);
      debug('uncaughtException', error);
      gateblu.cleanup();
    });
  };

  self.saveOptions = function(options){
    var optionsJSON = JSON.stringify(options, null, 2);
    fs.writeFileSync(CONFIG_PATH, optionsJSON);
    debug("saveOptions", "\n", optionsJSON);
  };
};

var gatebluCommand  = new GatebluCommand();
gatebluCommand.run();
