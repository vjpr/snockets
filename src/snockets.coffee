# [snockets](http://github.com/TrevorBurnham/snockets)

DepGraph = require 'dep-graph'

CoffeeScript = require 'coffee-script'
fs           = require 'fs'
path         = require 'path'
uglify       = require 'uglify-js'
_            = require 'underscore'
exists       = fs.existsSync or path.existsSync

debug = false
if debug
  logger =
    debug: (args...) -> console.log args...
else
  logger =
    debug: ->

module.exports = class Snockets
  constructor: (@options = {}) ->
    unless _.isArray @options.src
      @options.src = [@options.src or '.']

    # By default, Snockets uses only async file methods. You can pass the
    # option async: false to either of its methods if you want it to be
    # synchronous instead. In synchronous mode, you can use either callbacks or
    # return values
    #
    # ` js = snockets.getConcatenation 'dir/foo.coffee', async: false`
    @options.async ?= true

    @cache = {}
    @concatCache = {}
    @depGraph = new DepGraph

  # ## Public methods

  # Scan a file to update the dependency graph `depGraph`
  #
  # `snockets.scan 'dir/foo.coffee', (err, depGraph) -> ...`
  scan: (filePath, flags, callback) ->
    if typeof flags is 'function'
      callback = flags; flags = {}
    flags ?= {}
    flags.async ?= @options.async

    @updateDirectives filePath, flags, (err, graphChanged) =>
      if err
        if callback then return callback err else throw err
      callback? null, @depGraph, graphChanged
      @depGraph

  # Get a list of compiled JavaScripts corresponding to the dependency
  # chain (starting from the first required file to the requested file)
  #
  # `snockets.getCompiledChain 'dir/foo.coffee', (err, jsList) -> ...`
  #
  # Returns an Array of objects in the format
  # `[{filename: "dependency1.js", js: "// code"}, ...]
  #
  # Note that those JavaScript files are not actually created by
  # `getCompiledChain`.
  getCompiledChain: (filePath, flags, callback) ->
    if typeof flags is 'function'
      callback = flags; flags = {}
    flags ?= {}
    flags.async ?= @options.async

    @updateDirectives filePath, flags, (err, graphChanged) =>
      if err
        if callback then return callback err else throw err
      try
        chain = @depGraph.getChain filePath
      catch e
        if callback then return callback e else throw e

      compiledChain = for link in chain.concat filePath
        o = {}
        if @compileFile link
          o.filename = stripExt(link) + '.js'
        else
          o.filename = link
        o.js = @cache[link].js.toString 'utf8'
        o

      callback? null, compiledChain, graphChanged
      compiledChain

  # Return a single compiled, concatenated file (optionally run through UglifyJS
  # if the minify option is passed in)
  #
  # `snockets.getConcatenation 'dir/foo.coffee', minify: true, (err, js) -> ...`
  #
  # Note that you don't need to scan before or after running `getCompiledChain`
  # or # `getConcatenation`; they update the dependency graph the same way that
  # scan does.
  getConcatenation: (filePath, flags, callback) ->
    if typeof flags is 'function'
      callback = flags; flags = {}
    flags ?= {}
    flags.async ?= @options.async
    concatenationChanged = true

    @updateDirectives filePath, flags, (err, graphChanged) =>
      if err
        if callback then return callback err else throw err
      try
        if @concatCache[filePath]?.data
          concatenation = @concatCache[filePath].data.toString 'utf8'
          if !flags.minify then concatenationChanged = false
        else
          chain = @depGraph.getChain filePath
          concatenation = (for link in chain.concat filePath
            @compileFile link
            @cache[link].js.toString 'utf8'
          ).join '\n'
          @concatCache[filePath] = data: new Buffer(concatenation)
      catch e
        if callback then return callback e else throw e

      if flags.minify
        if @concatCache[filePath]?.minifiedData
          result = @concatCache[filePath].minifiedData.toString 'utf8'
          concatenationChanged = false
        else
          result = minify concatenation
          @concatCache[filePath].minifiedData = new Buffer(result)
      else
        result = concatenation

      callback? null, result, concatenationChanged
      result

  # ## Internal methods

  # Interprets the directives from the given file to update `@depGraph`.
  # TODO: We should allow absolute paths by searching from specified
  #   asset paths similar to sprockets.
  updateDirectives: (filePath, flags, excludes..., callback) ->
    return callback() if filePath in excludes
    excludes.push filePath

    depList = []
    graphChanged = false
    q = new HoldingQueue
      task: (depPath, next) =>
        return next() unless getExt depPath
        if depPath is filePath
          err = new Error("Script tries to require itself: #{filePath}")
          return callback err
        unless depPath in depList
          depList.push depPath
        @updateDirectives depPath, flags, excludes..., (err, depChanged) ->
          return callback err if err
          graphChanged or= depChanged
          next()
      onComplete: =>
        unless _.isEqual depList , @depGraph.map[filePath]
          @depGraph.map[filePath] = depList
          graphChanged = true
        if graphChanged
          @concatCache[filePath] = null
        callback null, graphChanged

    # `#= require dependency` or `#= require dep1 dep2` or #= require /dep1
    require = (relPath) =>
      logger.debug "\nProcessing 'require #{relPath}'"
      q.waitFor relName = stripExt relPath
      if relName.match EXPLICIT_PATH
        depPath = relName + '.js'
        q.perform relName, depPath
      else
        logger.debug "Searching all source roots for:"
        # The `relPath` can refer to two things:
        # 1. A file relative its current location.
        depName = @joinPath path.dirname(filePath), relName
        logger.debug "  #{depName}"
        # 2. A file relative to one of the source roots.
        logger.debug "  #{relPath}"

        # This method looks for both of them and returns the first it finds.
        @findMatchingFile relPath, depName, flags, (err, depPath) ->
          return callback err if err
          q.perform relName, depPath

    # `#= require_dir dir`
    requireTree = (dirName) =>
      q.waitFor dirName
      @readdir @absPath(dirName), flags, (err, items) =>
        return callback err if err
        q.unwaitFor dirName
        for item in items
          itemPath = @joinPath dirName, item
          continue if @absPath(itemPath) is @absPath(filePath)
          q.waitFor itemPath
          do (itemPath) =>
            @stat @absPath(itemPath), flags, (err, stats) =>
              return callback err if err
              if stats.isFile()
                q.perform itemPath, itemPath
              else
                requireTree itemPath
                q.unwaitFor itemPath

    @readFile filePath, flags, (err, fileChanged) =>
      return callback err if err
      if fileChanged then graphChanged = true
      for directive in parseDirectives(@cache[filePath].data.toString 'utf8')
        words = directive.replace(/['"]/g, '').split /\s+/
        [command, relPaths...] = words

        switch command
          when 'require'
            require relPath for relPath in relPaths
          when 'require_tree'
            for relPath in relPaths
              requireTree @joinPath path.dirname(filePath), relPath

      q.finalize()

  # Searches for a file with the given name (no extension, e.g. `'foo/bar'`)
  findMatchingFile: (relPath, filename, flags, callback) ->
    tryFiles = (file, filePaths) =>
      logger.debug "\n--- Looking for #{file}"
      for filePath in filePaths
        logger.debug "Is " + stripExt(@absPath filePath) + ' == ' + @absPath(file)
        if stripExt(@absPath filePath) is @absPath(file)
          callback null, filePath
          return true

    logger.debug "Trying cache"
    return if tryFiles filename, _.keys @cache

    # Search for `filename` in the same directory as the directive
    @readdir path.dirname(@absPath filename), flags, (err, files) =>
      return callback err if err
      return if tryFiles filename, (for file in files
        @joinPath path.dirname(filename), file
      )

      logger.debug "
        \n--- Cannot find file in same directory as it was required from.
        Checking other roots."

      # Search for 'relPath` in a matching source root or sub-directory
      # of that source root. (`@absPath()` will locate the matching source root)
      logger.debug "Checking directory containing file or file itself: " + @absPath relPath
      @readdir path.dirname(@absPath relPath), flags, (err, files) =>
        return callback err if err
        return if tryFiles relPath, (for file in files
          @joinPath path.dirname(relPath), file
        )
        callback new Error("File not found: '#{filename}'")

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
      if timeEq @cache[filePath]?.mtime, stats.mtime
        return callback null, false
      if flags.async
          fs.readFile @absPath(filePath), (err, data) =>
            return callback err if err
            @cache[filePath] = {mtime: stats.mtime, data}
            callback null, true
      else
        try
          data = fs.readFileSync @absPath(filePath)
          @cache[filePath] = {mtime: stats.mtime, data}
          callback null, true
        catch e
          callback e

  # Compile file if neccessary.
  #
  # Returns false if the file is a JavaScript file and compilation is not
  # required, or true if the file was compiled.
  compileFile: (filePath) ->
    if (ext = path.extname filePath) is '.js'
      @cache[filePath].js = @cache[filePath].data
      false
    else
      src = @cache[filePath].data.toString 'utf8'
      js = compilers[ext[1..]].compileSync @absPath(filePath), src
      @cache[filePath].js = new Buffer(js)
      true

  # Checks each source root for the existence of this path.
  #
  # If you have `assets/` and `vendor/` roots, it will search each of them
  # until if finds a match.
  absPath: (relPath) ->
    return relPath if relPath.match EXPLICIT_PATH

    # For each search path in `@options.src`, search for filename.
    # If found, return the absolute path to the first match.
    result = null
    _.any @options.src, (src) =>
      if src.match EXPLICIT_PATH
        candidate = @joinPath src, relPath
      else
        candidate = @joinPath process.cwd(), src, relPath
      result = candidate
      return true if exists(candidate)

      dir = path.dirname(candidate)
      if exists(dir) and fs.statSync(dir).isDirectory()
        for file in fs.readdirSync(dir)
          #logger.debug stripExt(file) + ' > ' + path.basename(candidate)
          return true if stripExt(file) is path.basename(candidate)

    result

  joinPath: ->
    filePath = path.join.apply path, arguments

    # Replace backslashes with forward slashes for Windows compatability
    if process.platform is 'win32'
      slash = '/' # / on the same line as the regex breaks ST2 syntax highlight
      filePath.replace /\\/g, slash
    else
      filePath

# ## Compilers

# When `updatingDirectives()` is called the key values from this object are
# added to the end of each directive when trying to find the matching file.
#
# To add a compiler (for example `.js.coffee`):
#
#   Snockets = require('snockets')
#   Snockets.compilers['js.coffee'] =
#     match: /\.js.coffee$/
#     compileSync: Snockets.compilers.coffee
#
module.exports.compilers = compilers =
  coffee:
    match: /\.js$/
    compileSync: (sourcePath, source) ->
      CoffeeScript.compile source, {filename: sourcePath}

  'js.coffee':
    match: /\.js$/
    compileSync: (sourcePath, source) ->
      CoffeeScript.compile source, {filename: sourcePath}

# ## Regexes

EXPLICIT_PATH = /^\/|:/

HEADER = ///
(?:
  (\#\#\# .* \#\#\#\n*) |
  (// .* \n*) |
  (\# .* \n*)
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

# Extract directives from code using regex
parseDirectives = (code) ->
  code = code.replace /[\r\t ]+$/gm, '\n'  # fix for issue #2
  return [] unless match = HEADER.exec(code)
  header = match[0]
  match[1] while match = DIRECTIVE.exec header

# Strip the extension from file. Extension with greatest number of components
# first.
stripExt = (filePath) ->
  if (ext = getExt filePath)
    extStart = filePath.indexOf(ext)
    return filePath[0...extStart]
  else
    filePath

# Returns the matching extension with greatest number of components,
# or null if no supported extension found
getExt = (filePath) ->
  for ext in jsExts()
    if filePath.match(ext+'$') then return ext
  return null

# Returns list of acceptable file extensions ordered by number of
# extension components within each extension
# (i.e. `.js.coffee` before `.coffee`)
# Default: `[ '.coffee', '.js' ]`
jsExts = ->
  exts = (ext for ext of compilers).concat('js')
  sortedExts = _.sortBy exts, (v) -> -(v.split('.').length - 1)
  (".#{ext}" for ext in sortedExts)

minify = (js) ->
  jsp = uglify.parser
  pro = uglify.uglify
  ast = jsp.parse js
  ast = pro.ast_mangle ast
  ast = pro.ast_squeeze ast
  pro.gen_code ast

timeEq = (date1, date2) ->
  date1? and date2? and date1.getTime() is date2.getTime()

module.exports.global = global
