{-# LANGUAGE NamedFieldPuns #-}

-- | Dead code elimination command based on `Language.PureScript.CoreFn.DCE`.
--
module Command.DCE
  ( runDCECommand
  ) where

import           Control.Monad
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Supply
import           Control.Monad.Trans (lift)
import           Control.Monad.Trans.Except
import qualified Data.Aeson as A
import           Data.Aeson.Internal (JSONPath)
import qualified Data.Aeson.Internal as A
import           Data.Aeson.Parser (eitherDecodeWith, json)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSL.Char8 (unpack)
import qualified Data.ByteString.Lazy.UTF8 as BU8
import           Data.Bool (bool)
import           Data.Either (Either, lefts, rights, partitionEithers)
import           Data.Foldable (for_, traverse_)
import           Data.List (null)
import qualified Data.Map as M
import           Data.Maybe (isNothing, listToMaybe)
import           Data.Monoid ((<>))
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy.Encoding as TE
import           Data.Version (Version)
import           Formatting (sformat, string, stext, (%))

import qualified Language.PureScript.Docs.Types as Docs
import qualified Language.JavaScript.Parser as JS
import qualified Language.PureScript as P
import qualified Language.PureScript.CoreFn as CoreFn
import qualified Language.PureScript.CoreFn.FromJSON as CoreFn
import qualified Language.PureScript.Errors.JSON as P
import qualified System.Console.ANSI as ANSI
import           System.Directory (doesDirectoryExist, getCurrentDirectory)
import           System.Exit (exitFailure, exitSuccess)
import           System.FilePath ((</>))
import           System.FilePath.Glob (compile, globDir1)
import           System.IO (hPutStrLn, stderr)

import           Command.Options
import           Language.PureScript.DCE.Errors (EntryPoint (..))

import           Language.PureScript.DCE ( DCEError (..)
                                         , Level (..)
                                         )
import qualified Language.PureScript.DCE as DCE


readInput :: [FilePath] -> IO [Either (FilePath, JSONPath, String) (Version, CoreFn.Module CoreFn.Ann)]
readInput inputFiles = forM inputFiles (\f -> addPath f . decodeCoreFn <$> BSL.readFile f)
  where
  decodeCoreFn :: BSL.ByteString -> Either (JSONPath, String) (Version, CoreFn.Module CoreFn.Ann)
  decodeCoreFn = eitherDecodeWith json (A.iparse CoreFn.moduleFromJSON)

  addPath
    :: FilePath
    -> Either (JSONPath, String) (Version, CoreFn.Module CoreFn.Ann)
    -> Either (FilePath, JSONPath, String) (Version, CoreFn.Module CoreFn.Ann)
  addPath f = either (Left . incl) Right
    where incl (l,r) = (f,l,r)


-- | Argumnets: verbose, use JSON, warnings, errors
--
printWarningsAndErrors
    :: Bool                      -- ^ be verbose
    -> Bool                      -- ^ use 'JSON'
    -> P.MultipleErrors          -- ^ warnings
    -> Either P.MultipleErrors a -- ^ errors
    -> IO ()
printWarningsAndErrors verbose False warnings errors = do
  pwd <- getCurrentDirectory
  cc <- bool Nothing (Just P.defaultCodeColor) <$> ANSI.hSupportsANSI stderr
  let ppeOpts = P.defaultPPEOptions { P.ppeCodeColor = cc, P.ppeFull = verbose, P.ppeRelativeDirectory = pwd }
  when (P.nonEmpty warnings) $
    hPutStrLn stderr (P.prettyPrintMultipleWarnings ppeOpts warnings)
  case errors of
    Left errs -> do
      hPutStrLn stderr (P.prettyPrintMultipleErrors ppeOpts errs)
      exitFailure
    Right _ -> return ()
printWarningsAndErrors verbose True warnings errors = do
  hPutStrLn stderr . BU8.toString . A.encode $
    P.JSONResult (P.toJSONErrors verbose P.Warning warnings)
               (either (P.toJSONErrors verbose P.Error) (const []) errors)
  either (const exitFailure) (const (return ())) errors


data DCEAppError
  = ParseErrors [Text]
  | InputNotDirectory FilePath
  | NoInputs FilePath
  | CompilationError (DCEError 'Error)


formatDCEAppError :: Options -> FilePath -> DCEAppError -> Text
formatDCEAppError opts _ (ParseErrors errs) =
  let errs' =
        if optVerbose opts
        then errs
        else take 5 errs ++ case length $ drop 5 errs of
          0 -> []
          x -> ["... (" <> T.pack (show x) <> " more)"]
  in sformat
        (string%": Failed parsing:\n  "%stext)
        (DCE.colorString DCE.errorColor "Error")
        (T.intercalate "\n\t" errs')
formatDCEAppError _ _ (NoInputs path)
  = sformat
        (stext%": No inputs found under "%string%" directory.\n"
              %"       Please run `purs compile --codegen corefn ..` or"
              %"`pulp build -- --codegen corefn`")
        (DCE.colorText DCE.errorColor "Error")
        (DCE.colorString DCE.codeColor path)
formatDCEAppError _ _ (InputNotDirectory path)
  = sformat
        (stext%": Directory "%string%" does not exists.")
        (DCE.colorText DCE.errorColor "Error")
        (DCE.colorString DCE.codeColor path)
formatDCEAppError _ relPath (CompilationError err)
  = T.pack $ DCE.displayDCEError relPath err


getEntryPoints
  :: [CoreFn.Module CoreFn.Ann]
  -> [EntryPoint]
  -> [Either EntryPoint (P.Qualified P.Ident)]
getEntryPoints mods = go []
  where
  go acc [] = acc
  go acc ((EntryPoint i) : eps)  = 
    if i `fnd` mods
      then go (Right i : acc) eps
      else go (Left (EntryPoint i)  : acc) eps
  go acc ((EntryModule mn) : eps) = go (modExports mn mods ++ acc) eps
  go acc ((err@EntryParseError{}) : eps) = go (Left err : acc) eps

  modExports :: P.ModuleName -> [CoreFn.Module CoreFn.Ann] -> [Either EntryPoint (P.Qualified P.Ident)]
  modExports mn [] = [Left (EntryModule mn)]
  modExports mn (CoreFn.Module{ CoreFn.moduleName, CoreFn.moduleExports } : ms)
    | mn == moduleName
    = (Right . flip P.mkQualified mn) `map` moduleExports
    | otherwise
    = modExports mn ms

  fnd :: P.Qualified P.Ident -> [CoreFn.Module CoreFn.Ann] -> Bool
  fnd _ [] = False
  fnd qi@(P.Qualified (Just mn) i) (CoreFn.Module{ CoreFn.moduleName, CoreFn.moduleExports } : ms)
    = if moduleName == mn && i `elem` moduleExports
        then True
        else fnd qi ms
  fnd _ _ = False


dceCommand :: Options -> ExceptT DCEAppError IO ()
dceCommand Options { optEntryPoints
                   , optInputDir
                   , optOutputDir
                   , optVerbose
                   , optForeign
                   , optPureScriptOptions
                   , optUsePrefix
                   , optJsonErrors
                   , optEvaluate
                   } = do
    -- initial checks
    inptDirExist <- lift $ doesDirectoryExist optInputDir
    unless inptDirExist $
      throwError (InputNotDirectory optInputDir)

    -- read files, parse errors
    let cfnGlb = compile "**/corefn.json"
    inpts <- liftIO $ globDir1 cfnGlb optInputDir >>= readInput
    let errs = lefts inpts
    unless (null errs) $
      throwError (ParseErrors $ formatError `map` errs)

    let mPursVer = fmap fst . listToMaybe . rights $ inpts
    when (isNothing mPursVer) $
      throwError (NoInputs optInputDir)

    let (notFound, entryPoints) = partitionEithers $ getEntryPoints (fmap snd . rights $ inpts) optEntryPoints

    when (not $ null notFound) $
      case filter DCE.isEntryParseError notFound of
        []   -> throwError (CompilationError $ EntryPointsNotFound notFound)
        perrs ->
          let fn (EntryParseError s) acc = s : acc
              fn _                   acc = acc
          in throwError (CompilationError $ EntryPointsNotParsed (foldr fn [] perrs))

    when (null $ entryPoints) $
      throwError (CompilationError $ NoEntryPoint)

    -- run `evaluate` and `runDeadCodeElimination` on `CoreFn` representation
    let mods = if optEvaluate
                  then DCE.runDeadCodeElimination
                        entryPoints
                        (DCE.evaluate (snd `map` rights inpts))
                  else DCE.runDeadCodeElimination
                        entryPoints
                        (snd `map` rights inpts)

    -- relPath <- liftIO getCurrentDirectory
    -- liftIO $ traverse_ (hPutStrLn stderr . uncurry (displayDCEWarning relPath)) (zip (zip [1..] (repeat (length warns))) warns)
    let filePathMap = M.fromList $ map (\m -> (CoreFn.moduleName m, Right $ CoreFn.modulePath m)) mods
    foreigns <- P.inferForeignModules filePathMap
    let makeActions = (P.buildMakeActions optOutputDir filePathMap foreigns optUsePrefix)
          -- run `runForeignModuleDeadCodeElimination` in `ffiCodeGen`
          { P.ffiCodegen = \CoreFn.Module{ CoreFn.moduleName, CoreFn.moduleForeign } -> liftIO $
                case moduleName `M.lookup` foreigns of
                  Nothing -> return ()
                  Just fp -> do
                    jsCode <- BSL.Char8.unpack <$> BSL.readFile fp
                    case JS.parse jsCode fp of
                      Left _ -> return ()
                      Right (JS.JSAstProgram ss ann) ->
                        let ss'    = DCE.runForeignModuleDeadCodeElimination moduleForeign ss
                            jsAst' = JS.JSAstProgram ss' ann
                            foreignFile = optOutputDir
                                      </> T.unpack (P.runModuleName moduleName)
                                      </> "foreign.js"
                        in BSL.writeFile foreignFile (TE.encodeUtf8 $ JS.renderToText jsAst')
                      Right _ -> return ()
          }
    (makeErrors, makeWarnings) <-
        liftIO
        $ P.runMake optPureScriptOptions
        $ runSupplyT 0
        $ traverse
            (\m ->
              P.codegen makeActions m
                        (Docs.Module (CoreFn.moduleName m) Nothing [] [])
                        (moduleToExternsFile m))
            mods
    when optForeign $
      traverse_ (liftIO . P.runMake optPureScriptOptions . P.ffiCodegen makeActions) mods

    -- copy extern files
    -- we do not have access to data to regenerate extern files (they relay on
    -- more information than is present in `CoreFn.Module`).
    for_ mods $ \m -> lift $ do
      let mn = P.runModuleName $ CoreFn.moduleName m
      exts <- BSL.readFile (optInputDir </> T.unpack mn </> "externs.json")
      BSL.writeFile (optOutputDir </> T.unpack mn </> "externs.json") exts
    liftIO $ printWarningsAndErrors (P.optionsVerboseErrors optPureScriptOptions) optJsonErrors
        (suppressFFIErrors makeWarnings)
        (either (Left . suppressFFIErrors) Right makeErrors)
    return ()
  where
    formatError :: (FilePath, JSONPath, String) -> Text
    formatError (f, p, err) =
      if optVerbose
        then sformat (string%":\n    "%string) f (A.formatError p err)
        else T.pack f

    -- a hack: purescript codegen function reads FFI from disk, and checks
    -- against it
    suppressFFIErrors :: P.MultipleErrors -> P.MultipleErrors
    suppressFFIErrors (P.MultipleErrors errs) = P.MultipleErrors $ filter fn errs
      where
      fn (P.ErrorMessage _ P.UnnecessaryFFIModule{})     = False
      fn (P.ErrorMessage _ P.UnusedFFIImplementations{}) = False
      fn _                                               = True

    moduleToExternsFile :: CoreFn.Module a -> P.ExternsFile
    moduleToExternsFile CoreFn.Module {CoreFn.moduleName} = P.ExternsFile {
        P.efVersion      = mempty,
        P.efModuleName   = moduleName,
        P.efExports      = [],
        P.efImports      = [],
        P.efFixities     = [],
        P.efTypeFixities = [],
        P.efDeclarations = [],
        P.efSourceSpan   = P.SourceSpan "none" (P.SourcePos 0 0) (P.SourcePos 0 0)
      }


runDCECommand
  :: Options
  -> IO ()
runDCECommand opts = do
  res <- runExceptT $ dceCommand opts
  relPath <- getCurrentDirectory
  case res of
    Left e  ->
         (hPutStrLn stderr . T.unpack . formatDCEAppError opts relPath $ e)
      *> exitFailure
    Right{} ->
      exitSuccess
