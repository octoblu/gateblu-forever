{EventEmitter} = require 'events'
DeviceManager = require '../index'

describe 'DeviceManager', ->
  beforeEach ->
    @sut = new DeviceManager {}

  it 'exist', ->
    expect(@sut).to.exist
