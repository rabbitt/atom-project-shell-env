{ spawnSync, execFileSync } = require "child_process"
{ Disposable, CompositeDisposable, File } = require "atom"

tap = (o, fn) -> fn(o); o

merge_env = (xs...) ->
  if xs?.length > 0
    tap {}, (m) -> m[k] = v for k, v of x for x in xs

Array::to_hash = ->
  tap {}, (m) => ([k,v] = kv.split(/\s*=\s*/); m[k] = v;) for kv in this

##
# Helper function: prints debug statement into atom's console if it started in dev mode.
#
debug = ( statements... ) ->
  if atom.config.get("000-project-shell-env.debug", atom.inDevMode())
    console.log "[project-shell-env] #{statements.join(" ")}"

##
# Helper function: escapes a string so that it can be safely used in a shell command line.
#
# @param [String] string
# @return [String]
#
shellEscape = ( string ) ->
  return string.replace( /([^A-Za-z0-9_\-.,:\/@])/, "\\$1" )

##
# Returns shell environment variables in the given directory as string.
#
# @param [String] path
# @param [Number] execution timeout
# @return [String]
#
getShellEnv = ( path, timeout = 1000 ) ->
  shell = atom.config.get("000-project-shell-env.shell_path", process.env["SHELL"] ? "bash")
  args  = [].concat( atom.config.get("000-project-shell-env.shell_args", [ "-l", "-i" ]))

  atom_home = new File(atom.configDirPath)
  environment =
    ATOM_HOME: process.env["ATOM_HOME"] ? atom_home
    NODE_PATH: process.env["NODE_PATH"]
    NODE_ENV:  process.env["NODE_ENV"]
    USER_HOME: process.env["HOME"] ? new File(atom_home).getParent()
    USER_NAME: process.env["USER"] ? new File(atom_home).getParent().getBaseName()

  environment = merge_env(environment,
                         (atom.config.get("000-project-shell-env.add_environment") ? {}).to_hash())

  # Marker string to mark command output
  marker = "--- 8< ---"

  # Script that will be passed as stdin to the shell
  script = [
    # Change directory or exit
    # NB: some tools (eg. RVM) can redefine "cd" command to execute some code
    "cd . 2>/dev/null || exit -1",

    # Print env inside markers
    "echo \"#{marker}\" && env && echo \"#{marker}\"",

    # Exit shell
    "exit 0"
  ]

  options =
    timeout: timeout ? 1000
    options:
      env: environment
    input: script.join("\n")

  shellResult = spawnSync shell, args, options

  # Throw timeout error
  throw shellResult.error if shellResult.error

  # Throw execution error
  throw new Error( shellResult.stderr.toString()) if shellResult.status != 0

  # Extract env from shell output
  shellStdout = shellResult.stdout.toString()

  return shellStdout.substring( shellStdout.indexOf( marker ) + marker.length,
                                shellStdout.lastIndexOf( marker ))

##
# Parses output of "env" utility and returns variable as hash.
#
# @param [String] env output
# @return [Object]
#
parseShellEnv = ( shellEnv ) ->
  env = {}

  shellEnv.trim().split( "\n" ).forEach ( line ) ->
    # Search for position of first occurrence of equal sign or throw error if it is not found
    ( eqlSign = line.indexOf( "=" )) > 0 or throw new Error( "Invalid env line: #{line}" )

    # Split string by found equal sign
    [ name, value ] = [ line.substring( 0, eqlSign ), line.substring( eqlSign + 1 ) ]

    env[ name ] = value

  return env

##
# Filters env variables using blacklist.
#
# @param [Object] env
# @param [Object] blacklist
# @return [Object]
#
filterEnv = ( env, blacklist = [] ) ->
  allowedVariables = Object.keys( env )

  # Apply blacklist
  if blacklist
    allowedVariables = allowedVariables.filter ( key ) -> key not in blacklist

  filteredEnv = {}
  filteredEnv[ key ] = env[ key ] for key in allowedVariables

  return filteredEnv

##
# Sets environment variables for current atom process. Returns disposable that
# will rollback all changes made.
#
# @param [Object] env variables
# @return [Disposable]
#
setAtomEnv = ( env ) ->
  # Disposable that will rollback all changes made to env
  disposable = new CompositeDisposable

  Object.keys( env ).forEach ( name ) ->
    newValue = env[ name ]
    oldValue = process.env[ name ]

    # Do nothing if env variable already set
    return if newValue == oldValue

    disposable.add new Disposable ->
      # If env variable wasn't changed set it back to original value
      if process.env[ name ] == newValue
        debug "#{name}: #{newValue} -> #{oldValue}"

        if oldValue?
          process.env[ name ] = oldValue
        else
          delete process.env[ name ]
      else
        debug "#{name} was changed – will not rollback to #{oldValue}"

    debug "#{name}: #{oldValue} -> #{newValue}"

    # Set new value
    process.env[ name ] = newValue

  return disposable

##
# Package class.
#
class ProjectShellEnv
  # ENV variables that NEVER will be loaded
  IGNORED_ENV = [
    "_",               # Contains previous command executed. Always equals to "env"
    "SHLVL",           # How deeply Bash is nested. Always equals to 3
    "NODE_PATH",       # Path for node modules. We MUST always use value provided by atom
    "LD_LIBRARY_PATH", # Path for shared libraries. Can cause serious problems (@see issue #2),
  ]

  # Shell timeout
  TIMEOUT = 3000

  DEFAULT_SHELL = process.env["SHELL"] ? "bash"
  DEFAULT_SHELL_ARGS = [ "-l", "-i", ]

  config:
    shell_path:
      order: 1
      description: "Path to shell to use for extracting environment variables"
      type: "string"
      default: DEFAULT_SHELL
    shell_args:
      order: 2
      description: "Arguments to pass to shell"
      type: "array"
      default: DEFAULT_SHELL_ARGS
      items:
        type: "string"
    add_environment:
      order: 3
      description: "List of environment key=value pairs to add to the environment (comma separated list)"
      type: "array"
      default: []
      items:
        type: "string"
    blacklist:
      order: 4
      description: "List of environment variables which will be ignored."
      type: "array"
      default: IGNORED_ENV
      items:
        type: "string"
    direnv:
      order: 5
      description: "Use direnv to set project specific environment"
      type: "boolean"
      default: false
    debug:
      order: 6
      description: "Show debugging output in console (requires restart, or Window: Reload)."
      type: "boolean"
      default: atom.inDevMode()

  activate: =>
    # Add our commands
    @commandsDisposable = atom.commands.add "atom-workspace",
      "project-shell-env:load": this.load,
      "project-shell-env:reset": this.reset

    # Automatically load env variables when atom started
    this.load()

    # Automatically reload env variables when project root is changed
    @changeProjectPathDisposable = atom.project.onDidChangePaths( this.load )

  deactivate: =>
    # Delete our commands and return original env variables
    @envDisposable?.dispose() and delete @envDisposable
    @commandsDisposable?.dispose() and delete @commandsDisposable
    @changeProjectPathDisposable?.dispose() and delete @changeProjectPathDisposable

  load: =>
    # Unload previous set variables
    this.reset()

    # Get project root path
    # TODO: we doesn't support multiple projects in 1 window!
    projectRoot = atom.project.getPaths()[ 0 ]

    debug "project root: #{projectRoot}"

    # Do nothing if there is no project root (this can happen for example when
    # user tries to open nonexistent file or directory).
    return unless projectRoot

    # Combine system and user's blacklists
    envBlacklist = [].concat( IGNORED_ENV ).concat( atom.config.get( "000-project-shell-env.blacklist" ))

    debug "blacklisted vars:", envBlacklist

    # Set project variables
    try
      @envDisposable = setAtomEnv( filterEnv( parseShellEnv( getShellEnv( projectRoot, TIMEOUT )), envBlacklist ))
    catch err
      # Throw error so specs will fail
      if atom.inSpecMode()
        throw err
      else
        atom.notifications.addError( err.toString(), dismissable: true )

  reset: =>
    @envDisposable?.dispose() and delete @envDisposable

module.exports = new ProjectShellEnv
