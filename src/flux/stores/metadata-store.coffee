_ = require 'underscore'

Reflux = require 'reflux'
Actions = require '../actions'
Metadata = require '../models/metadata'

EdgehillAPI = require '../edgehill-api'

DatabaseStore = require '../stores/database-store'
AccountStore = require '../stores/account-store'


CreateMetadataTask = require '../tasks/create-metadata-task'
DestroyMetadataTask = require '../tasks/destroy-metadata-task'

# TODO: This Store has to double cache data from the API and the DB with
# minor variation.  There's a task to refactor these stores into something
# like an `APIBackedStore` to abstract some of the complex logic out.

MAX_API_RATE = 1000

module.exports =
MetadataStore = Reflux.createStore
  init: ->
    @listenTo DatabaseStore, @_onDBChanged
    @listenTo AccountStore, @_onAccountChanged

    refreshDBFromAPI = _.debounce(_.bind(@_refreshDBFromAPI, @), MAX_API_RATE)
    @_typesToRefresh = {}

    @listenTo Actions.metadataError, (errorData) =>
      return unless errorData.type
      @_typesToRefresh[errorData.type] = true
      refreshDBFromAPI()
    @listenTo Actions.metadataCreated, (type) =>
      @_typesToRefresh[type] = true
      refreshDBFromAPI()
    @listenTo Actions.metadataDestroyed, (type) =>
      @_typesToRefresh[type] = true
      refreshDBFromAPI()

    @_accountId = AccountStore.current()?.id
    @_metadata = {}

    @_fullRefreshFromAPI()

    @_refreshCacheFromDB = _.debounce(_.bind(@_refreshCacheFromDB, @), 16)
    @_refreshCacheFromDB()

  # Returns a promise that will eventually return the metadata you want
  getMetadata: (type, publicId, key) ->
    if type? and publicId? and key?
      return @_metadata[type]?[publicId]?[key]
    else if type? and publicId?
      return @_metadata[type]?[publicId]
    else if type?
      return @_metadata[type]
    else return null

  _fullRefreshFromAPI: ->
    return if not atom.isMainWindow() or atom.inSpecMode()
    return unless @_accountId
    @_apiRequest() # The lack of type will request everything!

  _refreshDBFromAPI: ->
    return if not atom.isMainWindow() or atom.inSpecMode()
    types = Object.keys(@_typesToRefresh)
    @_typesToRefresh = {}
    promises = types.map (type) => @_apiRequest(type)
    Promise.settle(promises)

  _apiRequest: (type) ->
    typePath = if type then "/#{type}/" else "/"
    new Promise (resolve, reject) =>
      EdgehillAPI.request
        path: "/metadata/#{@_accountId}#{typePath}"
        success: (metadata) ->
          metadata = metadata?.results ? []
          metadata = metadata.map (metadatum) ->
            metadatum.publicId = metadatum.id
            return new Metadata(metadatum)
          if metadata.length is 0 then resolve()
          else
            DatabaseStore.persistModels(metadata).then(resolve).catch(reject)
        error: (apiError) ->
          reject(apiError)

  _onDBChanged: (change) ->
    return unless change.objectClass is Metadata.name
    @_refreshCacheFromDB()

  _refreshCacheFromDB: ->
    new Promise (resolve, reject) =>
      DatabaseStore.findAll(Metadata)
      .then (metadata=[]) =>
        @_metadata = {}
        for metadatum in metadata
          @_metadata[metadatum.type] ?= {}
          @_metadata[metadatum.type][metadatum.publicId] ?= {}
          @_metadata[metadatum.type][metadatum.publicId][metadatum.key] = metadatum.value
        @trigger()
        resolve()
      .catch (err) ->
        console.warn("Request for Metadata failed. #{err}")

  _onAccountChanged: ->
    @_accountId = AccountStore.current()?.id
    @_fullRefreshFromAPI()

  _deleteAllMetadata: ->
    DatabaseStore.findAll(Metadata).then (metadata) ->
      meatdata.forEach (metadatum) ->
        t = new DestroyMetadataTask(metadatum)
        Actions.queueTask(t)
