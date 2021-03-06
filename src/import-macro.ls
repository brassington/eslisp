# This module deals with transforming data between the form that is passed to
# user macros and returned from them, and the internal compiler AST form used
# otherwise.  Also, deals with inserting macros into compilation environments.

{ atom, list, string } = require \./ast
uuid = require \uuid .v4
ast-errors = require \./esvalid-partial
{ is-expression } = require \esutils .ast

statementify = require \./es-statementify

# This is only used to let macros return multiple statements, in a way
# detectable as different from other return types with an
# `instanceof`-check.
class multiple-statements
  (@statements) ~>

# macro function form → internal compiler-form
#
# To make user-defined macros simpler to write, they may return just plain JS
# values, which we'll read back here as AST nodes.  This makes macros easier
# to write and a little more tolerant of silliness.
to-compiler-form = (ast) ->

  # Stuff already in internal compiler form can stay that way.
  if ast instanceof [ string, atom ] then return ast

  # Lists' contents need to be converted, in case they've got
  # non-compiler-form stuff inside them.
  if ast instanceof list then return list ast.contents!map to-compiler-form

  # Multiple-statements just become an array of their contents, but like
  # lists, those contents might need conversion.
  if ast instanceof multiple-statements
    return ast.statements.map to-compiler-form

  # Everything else needs a little more thinking based on their type
  switch typeof! ast

    # Arrays represent lists
    | \Array  => list ast.map to-compiler-form

    # Objects are expected to represent atoms
    | \Object =>
      if ast.atom then atom ("" + ast.atom)
      else throw Error "Macro returned object without `atom` property, or atom property set to empty string (got #{JSON.stringify ast})"

    # Strings become strings as you'd expect
    | \String => string ast

    # Numbers become atoms
    | \Number => atom ("" + ast)

    # Undefined and null represent nothing
    | \Undefined => fallthrough
    | \Null      => null

    # Anything else errors
    | otherwise => throw Error "Unexpected macro return type #that"

to-macro-form = (compiler-form-ast) ->
  c = compiler-form-ast
  switch
  | c instanceof list   => c.contents!map to-macro-form
  | c instanceof string => c.text!
  | c instanceof atom
    if c.is-number! then Number c.text!
    else atom : c.text!
  | otherwise => throw Error "Internal error: Unexpected compiler AST value"

macro-env = (env) ->

  # Create the functions to be exposed for use in a macro's body based on the
  # given compilation environment

  evaluate : ->
    it |> to-compiler-form |> env.compile |> env.compile-to-js |> eval
  multi : (...args) -> multiple-statements args
  gensym : ->
    if arguments.length
      throw Error "Got #that arguments to `gensym`; expected none."
    atom "$#{uuid!.replace /-/g, \_}"
    # RFC4122 v4 UUIDs are based on random bits.  Hyphens become
    # underscores to make the UUID a valid JS identifier.
  is-expr : -> it |> to-compiler-form |> env.compile |> is-expression

compilerify-macro = (env, func) ->
  # Converts a userspace macro (which takes and returns lists and objects) into
  # a compilerspace macro (which takes and returns compiler AST nodes).

  env := env.derive-flattened!

  compilerspace-macro = (_, ...args) ->
    args .= map to-macro-form
    userspace-macro-result = func.apply (macro-env env), args

    internal-ast-form = to-compiler-form userspace-macro-result

    return switch
    | internal-ast-form is null => null
    | typeof! internal-ast-form is \Array => env.compile-many internal-ast-form
    | otherwise =>

      sm-ast = env.compile internal-ast-form

      switch sm-ast
      | null => null # happens if internal-ast-form was only macros
      | otherwise

        errors = ast-errors sm-ast
        if errors
          console.error "AST error at" sm-ast
          throw Error errors.0

        sm-ast

import-macro = (env, name, func) ->
  root-env = env.derive-root!
  import-capmacro root-env, name, func

import-capmacro = (env, name, func) ->
  import-compilerspace-macro env, name, compilerify-macro env, func

# Only used directly by aliases
import-compilerspace-macro = (env, name, func) ->
  env.import-macro name, func

# Only used by transform macros, which run on the initial AST
create-transform-macro = (env, func) ->
  (...args) ->
    args .= map to-macro-form
    userspace-macro-result = func.apply (macro-env env), args

    compilerspace-macro-result = to-compiler-form userspace-macro-result

    if compilerspace-macro-result instanceof Array
      return compilerspace-macro-result
    else return [ compilerspace-macro-result ]

module.exports = {
  import-macro,
  import-capmacro,
  import-compilerspace-macro,
  create-transform-macro,
  make-multiple-statements : multiple-statements
}
