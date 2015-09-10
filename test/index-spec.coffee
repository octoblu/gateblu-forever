{EventEmitter} = require 'events'
DeviceManager = require '../index'

describe 'DeviceManager', ->
  beforeEach ->
    @sut = new DeviceManager {}

  describe 'addDevice', ->
    beforeEach (done) ->
      @sut.stopDevice = sinon.stub().yields null
      @sut.installDeviceConnector = sinon.stub().yields null
      @sut.setupDevice = sinon.stub().yields null
      @sut.startDevice = sinon.stub().yields null
      @device = uuid: '1234', connector: 'meshblu:something'
      @sut.addDevice @device, => done()

    it 'should call installDeviceConnector', ->
      expect(@sut.installDeviceConnector).to.have.been.calledWith @device
