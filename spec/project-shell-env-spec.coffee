PACKAGE_NAME = "000-project-shell-env"
PACKAGE_NAMESPACE = "project-shell-env"

atom.config.set("#{PACKAGE_NAME}.debug", false)

describe "ProjectShellEnv", ->
  beforeEach ->
    waitsForPromise ->
      atom.packages.activatePackage PACKAGE_NAME

  afterEach ->
    atom.packages.deactivatePackage PACKAGE_NAME

  describe "when the project-shell-env:load event is triggered", ->
    beforeEach ->
      process.env['ENV_VAR_1'] = '42'
      process.env['ENV_VAR_2'] = 'test'
      process.env['ENV_VAR_3'] = 'yaa=haa'

    it "loads environment variables from shell in project directory", ->
      sendCommand "load"

      expect( process.env[ "ENV_VAR_1" ]).toEqual "42"
      expect( process.env[ "ENV_VAR_2" ]).toEqual "test"
      expect( process.env[ "ENV_VAR_3" ]).toEqual "yaa=haa"

  describe "when  project-shell-env:reset event is triggered", ->
    beforeEach ->
      sendCommand "load"

    it "unloads environment variables that were loaded with project-shell-env:load", ->
      sendCommand "reset"

      expect( process.env[ "ENV_VAR_1" ]).toBeUndefined
      expect( process.env[ "ENV_VAR_2" ]).toBeUndefined
      expect( process.env[ "ENV_VAR_3" ]).toBeUndefined

# HELPER FUNCTIONS

sendCommand = ( command ) ->
  workspaceElement = atom.views.getView( atom.workspace )
  atom.commands.dispatch( workspaceElement, "#{PACKAGE_NAMESPACE}:#{command}" )
