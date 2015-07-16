{EventEmitter} = require 'events'
ConnectorManager = require '../connector-manager'

describe 'ConnectorManager', ->
  beforeEach ->
    @sut = new ConnectorManager './tmp', 'connecteror'

  describe '-> install', ->
    it 'should exist', ->
      expect(@sut.install).to.exist
