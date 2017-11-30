module Commands where

import System.Exit (exitSuccess, exitFailure, exitWith, ExitCode(..))
import System.Process (callCommand, spawnCommand, waitForProcess)
import System.IO (hPutStr)
import Control.Concurrent (forkIO)
import Control.Monad.State.Lazy (StateT(..), runStateT, liftIO, modify, get, put)
import System.Directory
import System.Info (os)
import qualified Data.Map as Map
import Data.Maybe (fromJust, mapMaybe, isJust)
import Control.Monad
import Control.Exception
import Debug.Trace

import Parsing
import Emit
import Obj
import Types
import Infer
import Deftype
import ColorText
import Template
import Util
import Eval

data ReplCommand = Define XObj
                 | AddInclude Includer
                 | RegisterType String [XObj]

                 | ReplMacroError String
                 | ReplTypeError String
                 | ReplParseError String
                 | ReplCodegenError String

                 | ReplEval XObj
                 | ListOfCommands [ReplCommand]
                 | ListOfCallbacks [CommandCallback]
                 --deriving Show

-- | This function will show the resulting code of non-definitions.
-- | i.e. (Int.+ 2 3) => "_0 = 2 + 3"
consumeExpr :: Context -> XObj -> IO ReplCommand
consumeExpr ctx@(Context globalEnv typeEnv _ _ _ _) xobj =
  do (expansionResult, newCtx) <- runStateT (expandAll globalEnv xobj) ctx
     case expansionResult of
       Left err -> return (ReplMacroError (show err))
       Right expanded ->
         case annotate typeEnv globalEnv (setFullyQualifiedSymbols typeEnv globalEnv expanded) of
           Left err -> return (ReplTypeError (show err))
           Right annXObjs -> return (ListOfCallbacks (map printC annXObjs))

printC :: XObj -> CommandCallback
printC xobj =
  case checkForUnresolvedSymbols xobj of
    Left e ->
      (const (commandPrint [(XObj (Str (strWithColor Red (show e ++ ", can't print resulting code.\n"))) Nothing Nothing)]))
    Right _ ->
      (const (commandPrint [(XObj (Str (strWithColor Green (toC xobj))) Nothing Nothing)]))

objToCommand :: Context -> XObj -> IO ReplCommand
objToCommand ctx xobj =
  case obj xobj of
    Lst lst -> case lst of
                 [XObj Defn _ _, _, _, _] -> return $ Define xobj
                 [XObj Def _ _, _, _] ->return $  Define xobj
                 [XObj (Sym (SymPath _ "eval")) _ _, form] ->
                   return $ ReplEval form
                 XObj (Sym (SymPath _ "register-type")) _ _ : XObj (Sym (SymPath _ name)) _ _ : rest ->
                   return $  RegisterType name rest
                 _ -> return (ReplEval xobj)
    Sym (SymPath [] (':' : text)) -> return $ ListOfCallbacks (mapMaybe charToCommand text)
    _ -> return (ReplEval xobj)

charToCommand :: Char -> Maybe CommandCallback
charToCommand 'x' = Just commandRunExe
charToCommand 'r' = Just commandReload
charToCommand 'b' = Just commandBuild
charToCommand 'c' = Just commandCat
charToCommand 'e' = Just commandListBindings
charToCommand 'h' = Just commandHelp
charToCommand 'p' = Just commandProject
charToCommand 'q' = Just commandQuit
charToCommand _   = Just (\_ -> return dynamicNil)

define :: Context -> XObj -> IO Context
define ctx@(Context globalEnv typeEnv _ proj _ _) annXObj =
  -- Sort different kinds of definitions into the globalEnv or the typeEnv:
  case annXObj of
    XObj (Lst (XObj (Defalias _) _ _ : _)) _ _ ->
      --putStrLnWithColor Yellow (show (getPath annXObj) ++ " : " ++ show annXObj)
         return (ctx { contextTypeEnv = TypeEnv (envInsertAt (getTypeEnv typeEnv) (getPath annXObj) annXObj) })
    _ ->
      do --putStrLnWithColor Blue (show (getPath annXObj) ++ " : " ++ showMaybeTy (ty annXObj))
         when (projectEchoC proj) $
           putStrLn (toC annXObj)
         let ctx' = registerDefnInInterfaceIfNeeded ctx annXObj
         return (ctx' { contextGlobalEnv = envInsertAt globalEnv (getPath annXObj) annXObj })

registerDefnInInterfaceIfNeeded :: Context -> XObj -> Context
registerDefnInInterfaceIfNeeded ctx xobj =
  case xobj of
    XObj (Lst [XObj Defn _ _, XObj (Sym path) _ _, _, _]) _ _ ->
      -- This is a function, does it belong to an interface?
      registerInInterfaceIfNeeded ctx path
    _ ->
      ctx

registerInInterfaceIfNeeded :: Context -> SymPath -> Context
registerInInterfaceIfNeeded ctx path@(SymPath _ name) =
  let typeEnv = (getTypeEnv (contextTypeEnv ctx))
  in case lookupInEnv (SymPath [] name) typeEnv of
       Just (_, Binder (XObj (Lst [XObj (Interface interfaceSignature paths) ii it, isym]) i t)) ->
         let updatedInterface = XObj (Lst [XObj (Interface interfaceSignature (addIfNotPresent path paths)) ii it, isym]) i t
         in  ctx { contextTypeEnv = TypeEnv (extendEnv typeEnv name updatedInterface) }
       Just (_, Binder x) ->
         error ("A non-interface named '" ++ name ++ "' was found in the type environment: " ++ show x)
       Nothing ->
         ctx

popModulePath :: Context -> Context
popModulePath ctx = ctx { contextPath = init (contextPath ctx) }

executeCommand :: Context -> ReplCommand -> IO Context
executeCommand ctx@(Context env typeEnv pathStrings proj lastInput execMode) cmd =

  do when (isJust (envModuleName env)) $
       compilerError ("Global env module name is " ++ fromJust (envModuleName env) ++ " (should be Nothing).")

     case cmd of

       Define xobj ->
         let innerEnv = getEnv env pathStrings
         in  do (expansionResult, newCtx) <- runStateT (expandAll env xobj) ctx
                case expansionResult of
                  Left err -> executeCommand newCtx (ReplMacroError (show err))
                  Right expanded ->
                    let xobjFullPath = setFullyQualifiedDefn expanded (SymPath pathStrings (getName xobj))
                        xobjFullSymbols = setFullyQualifiedSymbols typeEnv innerEnv xobjFullPath
                    in case annotate typeEnv env xobjFullSymbols of
                         Left err -> executeCommand newCtx (ReplTypeError (show err))
                         Right annXObjs -> foldM define newCtx annXObjs

       RegisterType typeName rest ->
         let path = SymPath pathStrings typeName
             typeDefinition = XObj (Lst [XObj ExternalType Nothing Nothing, XObj (Sym path) Nothing Nothing]) Nothing (Just TypeTy)
             i = Nothing
         in  case rest of
               [] ->
                 return (ctx { contextTypeEnv = TypeEnv (extendEnv (getTypeEnv typeEnv) typeName typeDefinition) })
               members ->
                 case bindingsForRegisteredType typeEnv env pathStrings typeName members i of
                   Left errorMessage ->
                     do putStrLnWithColor Red errorMessage
                        return ctx
                   Right (typeModuleName, typeModuleXObj, deps) ->
                     let ctx' = (ctx { contextGlobalEnv = envInsertAt env (SymPath pathStrings typeModuleName) typeModuleXObj
                                     , contextTypeEnv = TypeEnv (extendEnv (getTypeEnv typeEnv) typeName typeDefinition)
                                     })
                     in foldM define ctx' deps

       ReplEval xobj ->
         do (result, newCtx) <- case xobj of
                                  XObj (Lst (f : args)) _ _ ->
                                    do (result', ctx') <- runStateT (eval env f) ctx
                                       case result' of
                                         Right (XObj (Lst ((XObj (Command callback) _ _) : _)) _ _) ->
                                           -- If a Command is called at the REPL it won't eval its args for the moment:
                                           runStateT ((getCommand callback) args) ctx'
                                         Right _ ->
                                           -- Not a Command, so will just eval normally:
                                           runStateT (eval env xobj) ctx'
                                         Left err ->
                                           return (Left err, ctx')
                                  _ ->
                                    runStateT (eval env xobj) ctx
            case result of
              Left e ->
                do putStrLnWithColor Red (show e)
                   return newCtx
              Right (XObj (Lst []) _ _) ->
                do return newCtx
              Right evaled ->
                do putStrLnWithColor Yellow ("=> " ++ (pretty evaled))
                   return newCtx

       ReplParseError e ->
         do putStrLnWithColor Red ("[PARSE ERROR] " ++ e)
            return ctx

       ReplMacroError e ->
         do putStrLnWithColor Red ("[MACRO ERROR] " ++ e)
            return ctx

       ReplTypeError e ->
         do putStrLnWithColor Red ("[TYPE ERROR] " ++ e)
            return ctx

       ReplCodegenError e ->
         do putStrLnWithColor Red ("[CODEGEN ERROR] " ++ e)
            return ctx

       ListOfCommands commands -> foldM executeCommand ctx commands

       ListOfCallbacks callbacks -> foldM (\ctx' cb -> callCallbackWithArgs ctx' cb []) ctx callbacks

callCallbackWithArgs :: Context -> CommandCallback -> [XObj] -> IO Context
callCallbackWithArgs ctx callback args =
  do (_, newCtx) <- runStateT (callback args) ctx
     return newCtx

data ShellOutException = ShellOutException { message :: String, returnCode :: Int } deriving (Eq, Show)

instance Exception ShellOutException

catcher :: Context -> ShellOutException -> IO Context
catcher ctx (ShellOutException message returnCode) =
  do putStrLnWithColor Red ("[RUNTIME ERROR] " ++ message)
     case contextExecMode ctx of
       Repl -> return ctx
       Build -> exitWith (ExitFailure returnCode)
       BuildAndRun -> exitWith (ExitFailure returnCode)

executeString :: Context -> String -> String -> IO Context
executeString ctx input fileName = catch exec (catcher ctx)
  where exec = case parse input fileName of
                 Left parseError -> executeCommand ctx (ReplParseError (show parseError))
                 Right xobjs -> foldM folder ctx xobjs

folder :: Context -> XObj -> IO Context
folder context xobj =
  do cmd <- objToCommand context xobj
     executeCommand context cmd

addCommand :: String -> CommandFunctionType -> (String, Binder)
addCommand name callback =
  let path = SymPath [] name
      cmd = XObj (Lst [XObj (Command callback) (Just dummyInfo) Nothing
                      ,XObj (Sym path) Nothing Nothing
                      ])
            (Just dummyInfo) (Just DynamicTy)
  in (name, Binder cmd)

type CommandCallback = [XObj] -> StateT Context IO (Either EvalError XObj)

-- | A toy command for trying out the new command system. TODO: Remove?
commandDestroy :: CommandCallback
commandDestroy args =
  do liftIO (putStrLn "DESTROY EVERYTHING!")
     modify (\ctx -> ctx { contextGlobalEnv = Env (Map.fromList []) Nothing Nothing [] ExternalEnv
                         , contextTypeEnv   = TypeEnv (Env (Map.fromList []) Nothing Nothing [] ExternalEnv)
                         })
     return dynamicNil

commandQuit :: CommandCallback
commandQuit args =
  do liftIO exitSuccess
     return dynamicNil

commandCat :: CommandCallback
commandCat args =
  do ctx <- get
     let outDir = projectOutDir (contextProj ctx)
         outMain = outDir ++ "main.c"
     liftIO $ do callCommand ("cat -n " ++ outMain)
                 return dynamicNil

commandRunExe :: CommandCallback
commandRunExe args =
  do ctx <- get
     let outDir = projectOutDir (contextProj ctx)
         outExe = outDir ++ "a.out"
     liftIO $ do handle <- spawnCommand outExe
                 exitCode <- waitForProcess handle
                 case exitCode of
                   ExitSuccess -> return (Right (XObj (Num IntTy 0) (Just dummyInfo) (Just IntTy)))
                   ExitFailure i -> throw (ShellOutException ("'" ++ outExe ++ "' exited with return value " ++ show i ++ ".") i)

commandBuild :: CommandCallback
commandBuild args =
  do ctx <- get
     let env = contextGlobalEnv ctx
         typeEnv = contextTypeEnv ctx
         proj = contextProj ctx
         src = do decl <- envToDeclarations typeEnv env
                  typeDecl <- envToDeclarations typeEnv (getTypeEnv typeEnv)
                  c <- envToC env
                  return ("//Types:\n" ++ typeDecl ++ "\n\n//Declarations:\n" ++ decl ++ "\n\n//Definitions:\n" ++ c)
     case src of
       Left err ->
         liftIO $ do putStrLnWithColor Red ("[CODEGEN ERROR] " ++ show err)
                     return dynamicNil
       Right okSrc ->
         liftIO $ do let incl = projectIncludesToC proj
                         includeCorePath = " -I" ++ projectCarpDir proj ++ "/core/ "
                         switches = " -g "
                         flags = projectFlags proj ++ includeCorePath ++ switches
                         outDir = projectOutDir proj
                         outMain = outDir ++ "main.c"
                         outExe = outDir ++ "a.out"
                         outLib = outDir ++ "lib.so"
                     createDirectoryIfMissing False outDir
                     writeFile outMain (incl ++ okSrc)
                     case Map.lookup "main" (envBindings env) of
                       Just _ -> do callCommand ("clang " ++ outMain ++ " -o " ++ outExe ++ " " ++ flags)
                                    putStrLn ("Compiled to '" ++ outExe ++ "'")
                                    return dynamicNil
                       Nothing -> do callCommand ("clang " ++ outMain ++ " -shared -o " ++ outLib ++ " " ++ flags)
                                     putStrLn ("Compiled to '" ++ outLib ++ "'")
                                     return dynamicNil

commandReload :: CommandCallback
commandReload args =
  do ctx <- get
     let paths = projectFiles (contextProj ctx)
         f :: Context -> FilePath -> IO Context
         f context filepath = do contents <- readFile filepath
                                 executeString context contents filepath
     newCtx <- liftIO (foldM f ctx paths)
     put newCtx
     return dynamicNil

commandListBindings :: CommandCallback
commandListBindings args =
  do ctx <- get
     liftIO $ do putStrLn "Types:\n"
                 putStrLn (prettyEnvironment (getTypeEnv (contextTypeEnv ctx)))
                 putStrLn "\nGlobal environment:\n"
                 putStrLn (prettyEnvironment (contextGlobalEnv ctx))
                 putStrLn ""
                 return dynamicNil

commandHelp :: CommandCallback

commandHelp [XObj (Sym (SymPath [] "about")) _ _] =
  liftIO $ do putStrLn "Carp is an ongoing research project by Erik Svedäng, et al."
              putStrLn ""
              putStrLn "Licensed under the Apache License, Version 2.0 (the \"License\"); \n\
                       \you may not use this file except in compliance with the License. \n\
                       \You may obtain a copy of the License at \n\
                       \http://www.apache.org/licenses/LICENSE-2.0"
              putStrLn ""
              putStrLn "THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY \n\
                       \EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \n\
                       \IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR \n\
                       \PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE \n\
                       \LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \n\
                       \CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF \n\
                       \SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR \n\
                       \BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, \n\
                       \WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE \n\
                       \OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN\n\
                       \IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "language")) _ _] =
  liftIO $ do putStrLn "Special forms:"
              putStrLn "(if <condition> <then> <else>)"
              putStrLn "(while <condition> <body>)"
              putStrLn "(do <statement1> <statement2> ... <exprN>)"
              putStrLn "(let [<sym1> <expr1> <name2> <expr2> ...] <body>)"
              --putStrLn "(fn [<args>] <body>)"
              putStrLn "(the <type> <expression>)"
              putStrLn "(ref <expression>)"
              putStrLn "(address <expr>)"
              putStrLn "(set! <var> <value>)"
              putStrLn ""
              putStrLn "To use functions in modules without qualifying them:"
              putStrLn "(use <module>)"
              putStrLn ""
              putStrLn ("Valid non-alphanumerics: " ++ validCharacters)
              putStrLn ""
              putStrLn "Number literals:"
              putStrLn "1      Int"
              putStrLn "1l     Int"
              putStrLn "1.0    Double"
              putStrLn "1.0f   Float"
              putStrLn ""
              putStrLn "Reader macros:"
              putStrLn "&<expr>   (ref <expr>)"
              putStrLn "@<expr>   (copy <expr>)"
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "macros")) _ _] =
  liftIO $ do putStrLn "Some useful macros:"
              putStrLn "(cond <condition1> <expr1> ... <else-condition>)"
              putStrLn "(for [<var> <from> <to>] <body>)"
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "structs")) _ _] =
  liftIO $ do putStrLn "A type definition will generate the following methods:"
              putStrLn "Getters  (<method-name> (Ref <struct>))"
              putStrLn "Setters  (set-<method-name> <struct> <new-value>)"
              putStrLn "Updaters (update-<method-name> <struct> <new-value>)"
              putStrLn "init (stack allocation)"
              putStrLn "new (heap allocation)"
              putStrLn "copy"
              putStrLn "delete (used internally, no need to call this explicitly)"
              putStrLn ""
              return dynamicNil

commandHelp [XObj (Sym (SymPath [] "shortcuts")) _ _] =
  liftIO $ do putStrLn "GHC-style shortcuts at the repl:"
              putStrLn "(reload)   :r"
              putStrLn "(build)    :b"
              putStrLn "(run)      :x"
              putStrLn "(cat)      :c"
              putStrLn "(env)      :e"
              putStrLn "(help)     :h"
              putStrLn "(project)  :p"
              putStrLn "(quit)     :q"
              putStrLn ""
              putStrLn "The shortcuts can be combined like this: \":rbx\""
              putStrLn ""
              return dynamicNil

commandHelp [] =
  liftIO $ do putStrLn "Compiler commands:"
              putStrLn "(load <file>)      - Load a .carp file, evaluate its content, and add it to the project."
              putStrLn "(reload)           - Reload all the project files."
              putStrLn "(build)            - Produce an executable or shared library."
              putStrLn "(run)              - Run the executable produced by 'build' (if available)."
              putStrLn "(cat)              - Look at the generated C code (make sure you build first)."
              putStrLn "(env)              - List the bindings in the global environment."
              putStrLn "(type <symbol>)    - Get the type of a binding."
              putStrLn "(info <symbol>)    - Get information about a binding."
              putStrLn "(project)          - Display information about your project."
              putStrLn "(quit)             - Terminate this Carp REPL."
              putStrLn "(help <chapter>)   - Available chapters: language, macros, structs, shortcuts, about."
              putStrLn ""
              putStrLn "To define things:"
              putStrLn "(def <name> <constant>)           - Define a global variable."
              putStrLn "(defn <name> [<args>] <body>)     - Define a function."
              putStrLn "(module <name> <def1> <def2> ...) - Define a module and/or add definitions to an existing one."
              putStrLn "(deftype <name> ...)              - Define a new type."
              putStrLn "(register <name> <type>)          - Make an external variable or function available for usage."
              putStrLn "(defalias <name> <type>)          - Create another name for a type."
              putStrLn ""
              putStrLn "C-compiler configuration:"
              putStrLn "(system-include <file>)          - Include a system header file."
              putStrLn "(local-include <file>)           - Include a local header file."
              putStrLn "(add-cflag <flag>)               - Add a cflag to the compilation step."
              putStrLn "(add-lib <flag>)                 - Add a library flag to the compilation step."
              putStrLn "(project-set! <setting> <value>) - Change a project setting (not fully implemented)."
              putStrLn ""
              putStrLn "Compiler flags:"
              putStrLn "-b                               - Build."
              putStrLn "-x                               - Build and run."
              return dynamicNil

commandHelp args =
  do liftIO $ putStrLn ("Can't find help for " ++ joinWithComma (map pretty args))
     return dynamicNil

commandProject :: CommandCallback
commandProject args =
  do ctx <- get
     liftIO (print (contextProj ctx))
     return dynamicNil

commandLoad :: CommandCallback
commandLoad [XObj (Str path) _ _] =
  do ctx <- get
     let proj = contextProj ctx
         carpDir = projectCarpDir proj
         fullSearchPaths =
           path :
           ("./" ++ path) :                                      -- the path from the current directory
           map (++ "/" ++ path) (projectCarpSearchPaths proj) ++ -- user defined search paths
           [carpDir ++ "/core/" ++ path]
            -- putStrLn ("Full search paths = " ++ show fullSearchPaths)
     existingPaths <- liftIO (filterM doesPathExist fullSearchPaths)
     case existingPaths of
       [] ->
         liftIO $ do putStrLnWithColor Red ("Invalid path " ++ path)
                     return dynamicNil
       firstPathFound : _ ->
         do contents <- liftIO $ do --putStrLn ("Will load '" ++ firstPathFound ++ "'")
                                    readFile firstPathFound
            let files = projectFiles proj
                files' = if firstPathFound `elem` files
                         then files
                         else firstPathFound : files
                proj' = proj { projectFiles = files' }
            newCtx <- liftIO $ executeString (ctx { contextProj = proj' }) contents firstPathFound
            put newCtx
            return dynamicNil

loadFiles :: Context -> [FilePath] -> IO Context
loadFiles ctxStart filesToLoad = foldM folder ctxStart filesToLoad
  where folder :: Context -> FilePath -> IO Context
        folder ctx file =
          callCallbackWithArgs ctx commandLoad [XObj (Str file) Nothing Nothing]

commandPrint :: CommandCallback
commandPrint args =
  do liftIO $ mapM_ (putStrLn . pretty) args
     return dynamicNil

commandExpand :: CommandCallback
commandExpand [xobj] =
  do ctx <- get
     result <-expandAll (contextGlobalEnv ctx) xobj
     case result of
       Left e ->
         liftIO $ do putStrLnWithColor Red (show e)
                     return dynamicNil
       Right expanded ->
         liftIO $ do putStrLnWithColor Yellow (pretty expanded)
                     return dynamicNil
commandExpand args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'expand' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandUse :: CommandCallback
commandUse [xobj@(XObj (Sym path) _ _)] =
  do ctx <- get
     let pathStrings = contextPath ctx
         env = contextGlobalEnv ctx
         e = getEnv env pathStrings
         useThese = envUseModules e
         e' = if path `elem` useThese then e else e { envUseModules = path : useThese }
         innerEnv = getEnv env pathStrings -- Duplication of e?
     case lookupInEnv path innerEnv of
       Just (_, Binder _) ->
         do put $ ctx { contextGlobalEnv = envReplaceEnvAt env pathStrings e' }
            return dynamicNil
       Nothing ->
         liftIO $ do putStrLnWithColor Red ("Can't find a module named '" ++ show path ++ "' at " ++ prettyInfoFromXObj xobj ++ ".")
                     return dynamicNil

commandType :: CommandCallback
commandType [xobj] =
  do ctx <- get
     let env = contextGlobalEnv ctx
     case xobj of
           XObj (Sym path@(SymPath _ name)) _ _ ->
             case lookupInEnv path env of
               Just (_, binder) ->
                 liftIO $ do putStrLnWithColor White (show binder)
                             return dynamicNil
               Nothing ->
                 case multiLookupALL name env of
                   [] ->
                     liftIO $ do putStrLnWithColor Red ("Can't find '" ++ show path ++ "'")
                                 return dynamicNil
                   binders ->
                     liftIO $ do mapM_ (\(env, binder) -> putStrLnWithColor White (show binder)) binders
                                 return dynamicNil
           _ ->
             liftIO $ do putStrLnWithColor Red ("Can't get the type of non-symbol: " ++ pretty xobj)
                         return dynamicNil
commandType args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'type' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandInfo :: CommandCallback
commandInfo [xobj@(XObj (Sym path@(SymPath _ name)) _ _)] =
  do ctx <- get
     let env = contextGlobalEnv ctx
         typeEnv = contextTypeEnv ctx
         proj = contextProj ctx
         printer binderPair =
           case binderPair of
             Just (_, binder@(Binder xobj@(XObj _ (Just i) _))) ->
               do putStrLnWithColor White (show binder ++ "\nDefined at " ++ prettyInfo i)
                  when (projectPrintTypedAST proj) $ putStrLnWithColor Yellow (prettyTyped xobj)
                  return ()
             Just (_, binder@(Binder xobj)) ->
               do putStrLnWithColor White (show binder)
                  when (projectPrintTypedAST proj) $ putStrLnWithColor Yellow (prettyTyped xobj)
                  return ()
             Nothing ->
               case multiLookupALL name env of
                 [] ->
                   do putStrLnWithColor Red ("Can't find '" ++ show path ++ "'")
                      return ()
                 binders ->
                   do mapM_ (\(env, binder@(Binder (XObj _ i _))) ->
                               case i of
                                 Just i' -> putStrLnWithColor White (show binder ++ " Defined at " ++ prettyInfo i')
                                 Nothing -> putStrLnWithColor White (show binder))
                        binders
                      return ()
     case xobj of
       XObj (Sym path@(SymPath _ name)) _ _ ->
         -- First look in the type env, then in the global env:
         do case lookupInEnv path (getTypeEnv typeEnv) of
              Nothing -> return ()
              found -> liftIO (printer found)
            liftIO (printer (lookupInEnv path env))
            return dynamicNil
       _ ->
         liftIO $ do putStrLnWithColor Red ("Can't get info from non-symbol: " ++ pretty xobj)
                     return dynamicNil
commandInfo args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'info' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandProjectSet :: CommandCallback
commandProjectSet [XObj (Str key) _ _, value] =
  do ctx <- get
     let proj = contextProj ctx
         env = contextGlobalEnv ctx
     Right evaledValue <- eval env value -- TODO: fix!!!
     let (XObj (Str valueStr) _ _) = evaledValue
     newCtx <- case key of
                 "cflag" -> return ctx { contextProj = proj { projectCFlags = addIfNotPresent valueStr (projectCFlags proj) } }
                 "libflag" -> return ctx { contextProj = proj { projectCFlags = addIfNotPresent valueStr (projectCFlags proj) } }
                 "prompt" -> return ctx { contextProj = proj { projectPrompt = valueStr } }
                 "search-path" -> return ctx { contextProj = proj { projectCarpSearchPaths = addIfNotPresent valueStr (projectCarpSearchPaths proj) } }
                 "printAST" -> return ctx { contextProj = proj { projectPrintTypedAST = (valueStr == "true") } }
                 "echoC" -> return ctx { contextProj = proj { projectEchoC = (valueStr == "true") } }
                 _ ->
                   liftIO $ do putStrLnWithColor Red ("Unrecognized key: '" ++ key ++ "'")
                               return ctx
     put newCtx
     return dynamicNil
commandProjectSet args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'project-set!' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandOS :: CommandCallback
commandOS _ =
  return (Right (XObj (Str os) (Just dummyInfo) (Just StringTy)))

commandRegister :: CommandCallback
commandRegister [(XObj (Sym (SymPath _ name)) _ _), typeXObj] =
  do ctx <- get
     let pathStrings = contextPath ctx
         env = contextGlobalEnv ctx
     case xobjToTy typeXObj of
           Just t -> let path = SymPath pathStrings name
                         binding = XObj (Lst [XObj External Nothing Nothing,
                                              XObj (Sym path) Nothing Nothing])
                                   (info typeXObj) (Just t)
                         env' = envInsertAt env path binding
                         ctx' = registerInInterfaceIfNeeded ctx path
                     in  do put (ctx' { contextGlobalEnv = env' })
                            return dynamicNil
           Nothing -> do liftIO $ putStrLnWithColor Red ("Can't understand type when registering '" ++ name ++ "'")
                         return dynamicNil
commandRegister args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'register' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandDefinterface :: CommandCallback
commandDefinterface [nameXObj@(XObj (Sym (SymPath [] name)) _ _), typeXObj] =
  do ctx <- get
     let env = contextGlobalEnv ctx
         typeEnv = contextTypeEnv ctx
     case xobjToTy typeXObj of
       Just t ->
         let interface = defineInterface name t [] (info nameXObj)
             typeEnv' = TypeEnv (envInsertAt (getTypeEnv typeEnv) (SymPath [] name) interface)
         in  do put (ctx { contextTypeEnv = typeEnv' })
                return dynamicNil
       Nothing ->
         liftIO $ do putStrLnWithColor Red ("Invalid type for interface '" ++ name ++ "': " ++
                                            pretty typeXObj ++ " at " ++ prettyInfoFromXObj typeXObj ++ ".")
                     return dynamicNil

commandDefmacro :: CommandCallback
commandDefmacro [(XObj (Sym (SymPath [] name)) _ _), params, body] =
  do ctx <- get
     let pathStrings = contextPath ctx
         env = contextGlobalEnv ctx
         path = SymPath pathStrings name
         macro = XObj (Lst [XObj Macro Nothing Nothing, XObj (Sym path) Nothing Nothing, params, body]) (info body) (Just MacroTy)
     put (ctx { contextGlobalEnv = envInsertAt env path macro })
     return dynamicNil
commandMacro args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'defmacro' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandDefdynamic :: CommandCallback
commandDefdynamic [(XObj (Sym (SymPath [] name)) _ _), params, body] =
  do ctx <- get
     let pathStrings = contextPath ctx
         env = contextGlobalEnv ctx
         path = SymPath pathStrings name
         dynamic = XObj (Lst [XObj Dynamic Nothing Nothing, XObj (Sym path) Nothing Nothing, params, body]) (info body) (Just DynamicTy)
     put (ctx { contextGlobalEnv = envInsertAt env path dynamic })
     return dynamicNil
commandDefdynamic args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'defdynamic' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandDeftype :: CommandCallback
commandDeftype (nameXObj : rest) =
  do ctx <- get
     let pathStrings = contextPath ctx
         env = contextGlobalEnv ctx
         typeEnv = contextTypeEnv ctx
     case nameXObj of
       XObj (Sym (SymPath _ typeName)) i _ ->
         case moduleForDeftype typeEnv env pathStrings typeName rest i of
           Right (typeModuleName, typeModuleXObj, deps) ->
             let typeDefinition =
                   -- NOTE: The type binding is needed to emit the type definition and all the member functions of the type.
                   XObj (Lst (XObj Typ Nothing Nothing : XObj (Sym (SymPath pathStrings typeName)) Nothing Nothing : rest)) i (Just TypeTy)
                 ctx' = (ctx { contextGlobalEnv = envInsertAt env (SymPath pathStrings typeModuleName) typeModuleXObj
                             , contextTypeEnv = TypeEnv (extendEnv (getTypeEnv typeEnv) typeName typeDefinition)
                             })
             in do ctxWithDeps <- liftIO (foldM define ctx' deps)
                   put $ foldl (\context path -> registerInInterfaceIfNeeded context path) ctxWithDeps
                               [(SymPath (pathStrings ++ [typeModuleName]) "str")
                               ,(SymPath (pathStrings ++ [typeModuleName]) "copy")]
                   return dynamicNil
           Left errorMessage ->
             liftIO $ do putStrLnWithColor Red ("Invalid type definition for '" ++ pretty nameXObj ++ "'. " ++ errorMessage)
                         return dynamicNil
       _ ->
         liftIO $ do putStrLnWithColor Red ("Invalid name for type definition: " ++ pretty nameXObj)
                     return dynamicNil
commandDeftype args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'deftype' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandDefmodule :: CommandCallback
commandDefmodule (xobj@(XObj (Sym (SymPath [] moduleName)) _ _) : innerExpressions) =
  do ctx <- get
     let pathStrings = contextPath ctx
         env = contextGlobalEnv ctx
         typeEnv = contextTypeEnv ctx
         lastInput = contextLastInput ctx
         execMode = contextExecMode ctx
         proj = contextProj ctx
     case lookupInEnv (SymPath pathStrings moduleName) env of
       Just (_, Binder (XObj (Mod _) _ _)) ->
         do ctxAfterModuleAdditions <- liftIO $ foldM folder (Context env typeEnv (pathStrings ++ [moduleName]) proj lastInput execMode) innerExpressions
            put (popModulePath ctxAfterModuleAdditions)
            return dynamicNil
       Just _ ->
         liftIO $ do putStrLnWithColor Red ("Can't redefine '" ++ moduleName ++ "' as module.")
                     return dynamicNil
       Nothing ->
         do let parentEnv = getEnv env pathStrings
                innerEnv = Env (Map.fromList []) (Just parentEnv) (Just moduleName) [] ExternalEnv
                newModule = XObj (Mod innerEnv) (info xobj) (Just ModuleTy)
                globalEnvWithModuleAdded = envInsertAt env (SymPath pathStrings moduleName) newModule
                ctx' = Context globalEnvWithModuleAdded typeEnv (pathStrings ++ [moduleName]) proj lastInput execMode
            ctxAfterModuleDef <- liftIO (foldM folder ctx' innerExpressions)
            put (popModulePath ctxAfterModuleDef)
            return dynamicNil
commandDefmodule args =
  liftIO $ do putStrLnWithColor Red ("Invalid args to 'defmodule' command: " ++ joinWithComma (map pretty args))
              return dynamicNil

commandAddInclude :: (String -> Includer) -> CommandCallback
commandAddInclude includerConstructor [XObj (Str file) _ _] =
  do ctx <- get
     let proj = contextProj ctx
         includer = includerConstructor file
         includers = projectIncludes proj
         includers' = if includer `elem` includers
                      then includers
                      else includer : includers
         proj' = proj { projectIncludes = includers' }
     put (ctx { contextProj = proj' })
     return dynamicNil

commandAddSystemInclude = commandAddInclude SystemInclude
commandAddLocalInclude  = commandAddInclude LocalInclude
