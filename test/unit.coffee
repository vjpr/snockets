#Snockets = require '../lib/snockets'
#src = '../test/assets'
#snockets = new Snockets({src})
#
#testSuite =
#  'Sort extensions': (test) ->
#    Snockets.compilers['js.coffee'] =
#      match: /\.js.coffee$/
#      compileSync: Snockets.compilers.coffee.compileSync
#    snockets.
#    test.deepEqual Snockets.global.jsExts, ['.js.coffee', '.coffee', '.js']
#    test.done()
#
## Every test runs both synchronously and asynchronously.
#for name, func of testSuite
#  do (func) ->
#    exports[name] = (test) ->
#      snockets.options.async = true;  func(test)
#    exports[name + ' (sync)'] = (test) ->
#      snockets.options.async = false; func(test)
