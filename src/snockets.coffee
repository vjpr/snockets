# [snockets](http://github.com/TrevorBurnham/snockets)

DepGraph = require 'dep-graph'

CoffeeScript = require 'coffee-script'
fs           = require 'fs'
path         = require 'path'
uglify       = require 'uglify-js'
_            = require 'underscore'

module.exports = class Snockets
  constructor: (@options = {}) ->
    @options.src ?= '.'
    @options.async ?= true
    @cache = {}
    @depGraph = new DepGraph

  # ## Public methods

  scan: (filePath, flags, callback) ->
    if typeof flags is 'function'
      callback = flags; flags = {}
    flags ?= {}
    flags.async ?= @options.async

    @readFile filePath, flags, (err) =>
      return callback err if err
      @compileFile filePath
      @updateDirectives filePath, flags, (err) =>
        return callback err if err

        if callback then callback null, @depGraph else return @depGraph
    @depGraph unless callback

  getCompiledChain: (filePath, flags, callback) ->
    if typeof flags is 'function'
      callback = flags; flags = {}
    flags ?= {}
    flags.async ?= @options.async

    # TODO

  getConcatenation: (filePath, flags, callback) ->
    if typeof flags is 'function'
      callback = flags; flags = {}
    flags ?= {}
    flags.async ?= @options.async

    # TODO

  # ## Internal methods

  # Searches for a file with the given name (no extension, e.g. `'foo/bar'`)
  findMatchingFile: (filename, flags, callback) ->
    tryFiles = (filePaths, required) =>
      for filePath in filePaths
        if stripExt(@absPath filePath) is filename
          callback null, filePath
          return true
      if required
        err = new Error("File not found: '#{filename}'")
        callback err

    return if tryFiles @cache, false
    @readdir path.dirname(filename), flags, (err, files) =>
      return callback err if err
      tryFiles files, true

  # Wrapper around fs.readdir or fs.readdirSync, depending on flags.async.
  readdir: (dir, flags, callback) ->
    if flags.async
      fs.readdir @absPath(dir), callback
    else
      try
        files = fs.readdirSync @absPath(dir)
        callback null, files
      catch e
        callback e

  # Wrapper around fs.stat or fs.statSync, depending on flags.async.
  stat: (filePath, flags, callback) ->
    if flags.async
      fs.stat @absPath(filePath), callback
    else
      try
        stats = fs.statSync @absPath(filePath)
        callback null, stats
      catch e
        callback e

  # Reads a file's data and timestamp into the cache.
  readFile: (filePath, flags, callback) ->
    @stat filePath, flags, (err, stats) =>
      return callback err if err
      if flags.async
          return callback() if timeEq @cache[filePath]?.mtime, stats.mtime
          fs.readFile @absPath(filePath), (err, data) =>
            return callback err if err
            @cache[filePath] = {mtime: stats.mtime, data}
            callback()
      else
        data = fs.readFileSync @absPath(filePath)
        @cache[filePath] = {mtime: stats.mtime, data}
        callback()

  # Interprets the directives from the given file to update `@depGraph`.
  updateDirectives: (filePath, flags, excludes..., callback) ->
    return callback() if filePath in excludes
    excludes.push filePath

    depList = []
    q = new HoldingQueue
      task: (depPath, next) =>
        if depPath is filePath
          err = new Error("Script tries to require itself: #{filePath}")
          return callback err
        depList.push depPath
        @readFile depPath, flags, (err) =>
          return callback err if err
          @updateDirectives depPath, flags, excludes..., (err) ->
            return callback err if err
            next()
      onComplete: =>
        @depGraph.map[filePath] = depList
        callback()

    require = (relPath) =>
      q.waitFor relName = stripExt relPath
      if relName.match EXPLICIT_PATH
        depPath = relName + '.js'
        q.perform relName, depPath
      else
        depName = path.join path.dirname(filePath), relName
        @findMatchingFile @absPath(depName), flags, (err, depPath) ->
          return callback err if err
          q.perform relName, depPath

    requireTree = (relPath) =>
      q.waitFor relPath
      dirName = path.join path.dirname((filePath)), relPath
      @readdir @absPath(dirName), flags, (err, items) =>
        return callback err if err
        q.unwaitFor relPath
        for item in items
          itemPath = path.join(dirName, item)
          continue if @absPath(itemPath) is @absPath(filePath)
          q.waitFor itemPath
          do (itemPath) =>
            @stat @absPath(itemPath), flags, (err, stats) =>
              return callback err if err
              if stats.isFile()
                if path.extname(itemPath) in jsExts()
                  q.perform itemPath, itemPath
                else
                  return q.unwaitFor itemPath
              else if stats.isDirectory()
                requireTree itemPath

    for directive in parseDirectives(@cache[filePath].data.toString 'utf8')
      words = directive.replace(/['"]/g, '').split /\s+/
      [command, relPaths...] = words

      switch command
        when 'require'
          require relPath for relPath in relPaths
        when 'require_tree'
          requireTree relPath for relPath in relPaths

    q.finalize()

  compileFile: (filePath) ->
    if (ext = path.extname filePath) is '.js'
      @cache[filePath].js = @cache[filePath].data
    else
      src = @cache[filePath].data.toString 'utf8'
      js = compilers[ext[1..]].compileSync @absPath(filePath), src
      @cache[filePath].js = new Buffer(js)
    return

  absPath: (relPath) ->
    if relPath.match EXPLICIT_PATH
      relPath
    else
      path.join process.cwd(), @options.src, relPath

# ## Compilers

module.exports.compilers = compilers =
  coffee:
    match: /\.js$/
    compileSync: (filePath, source) ->
      CoffeeScript.compile source, {filename: filePath}

# ## Regexes

BEFORE_DOT = /([^.]*)(\..*)?$/

EXPLICIT_PATH = /^\/|^\.|:/

HEADER = ///
(?:
  (\#\#\# .* \#\#\#\n?) |
  (// .* \n?) |
  (\# .* \n?)
)+
///

DIRECTIVE = ///
^[\W] *= \s* (\w+.*?) (\*\\/)?$
///gm

# ## Utility functions

class HoldingQueue
  constructor: ({@task, @onComplete}) ->
    @holdKeys = []
  waitFor: (key) ->
    @holdKeys.push key
  unwaitFor: (key) ->
    @holdKeys = _.without @holdKeys, key
  perform: (key, args...) ->
    @task args..., => @unwaitFor key
  finalize: ->
    if @holdKeys.length is 0
      @onComplete()
    else
      h = setInterval (=>
        if @holdKeys.length is 0
          @onComplete()
          clearInterval h
      ), 10

parseDirectives = (code) ->
  return [] unless match = HEADER.exec(code)
  header = match[0]
  match[1] while match = DIRECTIVE.exec header

stripExt = (filePath) ->
  BEFORE_DOT.exec(filePath)[1]

jsExts = ->
  (".#{ext}" for ext of compilers).concat '.js'

timeEq = (date1, date2) ->
  date1? and date2? and date1.getTime() is date2.getTime()