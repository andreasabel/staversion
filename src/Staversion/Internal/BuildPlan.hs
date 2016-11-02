-- |
-- Module: Staversion.Internal.BuildPlan
-- Description:  Handle build plan YAML files.
-- Maintainer: Toshio Ito <debug.ito@gmail.com>
--
-- __This is an internal module. End-users should not use it.__
module Staversion.Internal.BuildPlan
       ( -- * Entry APIs
         BuildPlan,
         packageVersion,
         BuildPlanManager,
         newBuildPlanManager,
         loadBuildPlan,
         -- * Low-level APIs
         loadBuildPlanYAML,
         parseVersionText,
         -- * For tests
         _setDisambiguator
       ) where

import Control.Applicative (empty, (<$>), (<*>))
import Control.Exception (throwIO, catchJust, IOException)
import Data.Aeson (FromJSON(..), (.:), Value(..), Object)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (listToMaybe)
import Data.Monoid ((<>))
import Data.Text (Text, unpack)
import Data.Traversable (Traversable(traverse))
import Data.Version (Version, parseVersion)
import qualified Data.Yaml as Yaml
import System.FilePath ((</>), (<.>))
import qualified System.IO.Error as IOE
import Text.Read (readMaybe)
import Text.ParserCombinators.ReadP (readP_to_S)

import Staversion.Internal.Log
  ( Logger, logDebug, logWarn
  )
import Staversion.Internal.HTTP (niceHTTPManager, Manager)
import Staversion.Internal.Query
 ( PackageName, PackageSource(..),
   ErrorMsg, Resolver
 )
import Staversion.Internal.BuildPlan.Stackage
  ( Disambiguator,
    loadBuildPlanYAMLForResolver,
    parseResolverString
  )

-- | A data structure that keeps a map between package names and their
-- versions.
newtype BuildPlan = BuildPlan (HM.HashMap PackageName Version)

instance FromJSON BuildPlan where
  parseJSON (Object object) = (\p1 p2 -> BuildPlan $ p1 <> p2) <$> core_packages <*> other_packages where
    core_packages = parseSysInfo =<< (object .: "system-info")
    parseSysInfo (Object o) = parseCorePackages =<< (o .: "core-packages")
    parseSysInfo _ = empty
    parseCorePackages (Object o) = traverse (\v -> versionParser =<< parseJSON v) o
    parseCorePackages _ = empty

    other_packages = parsePackages =<< (object .: "packages")
    parsePackages (Object o) = traverse parsePackageObject o
    parsePackages _ = empty
    parsePackageObject (Object o) = versionParser =<< (o .: "version")
    parsePackageObject _ = empty
    versionParser = maybe empty return . parseVersionText
  parseJSON _ = empty

-- | Stateful manager for 'BuildPlan's.
data BuildPlanManager =
  BuildPlanManager { manBuildPlanDir :: FilePath,
                     -- ^ path to the directory where build plans are hold.
                     manHttpManager :: Maybe Manager,
                     -- ^ low-level HTTP connection manager. If 'Nothing', it won't fetch build plans over the network.
                     manDisambiguator :: IORef (Maybe Disambiguator),
                     -- ^ cache of resolver disambigutor
                     manLogger :: Logger
                   }

newBuildPlanManager :: FilePath -- ^ path to the directory where build plans are hold.
                    -> Logger
                    -> Bool -- ^ If 'True', it queries the Internet for build plans. Otherwise, it won't.
                    -> IO BuildPlanManager
newBuildPlanManager plan_dir logger enable_network = do
  mman <- if enable_network
          then Just <$> niceHTTPManager
          else return Nothing
  disam <- newIORef Nothing
  return $ BuildPlanManager { manBuildPlanDir = plan_dir,
                              manHttpManager = mman,
                              manDisambiguator = disam,
                              manLogger = logger
                            }

loggedElse :: Logger
           -> IO (Either ErrorMsg a) -- ^ first action tried.
           -> IO (Either ErrorMsg a) -- ^ the action executed if the first action returns 'Left'.
           -> IO (Either ErrorMsg a)
loggedElse logger first second = do
  eret <- first
  case eret of
   Right _ -> return eret
   Left e -> logWarn logger e >> second

loadBuildPlan :: BuildPlanManager -> PackageSource -> IO (Either ErrorMsg BuildPlan)
loadBuildPlan man (SourceStackage resolver) =
  loadBuildPlan_stackageLocalFile man resolver `loggedElse'` loadBuildPlan_stackageNetwork man resolver
  where
    loggedElse' = loggedElse $ manLogger man

loadBuildPlan_stackageLocalFile :: BuildPlanManager -> Resolver -> IO (Either ErrorMsg BuildPlan)
loadBuildPlan_stackageLocalFile man resolver = catchJust handleIOError doLoad (return . Left) where
  yaml_file = manBuildPlanDir man </> resolver <.> "yaml"
  doLoad = do
    logDebug (manLogger man) ("Read " ++ yaml_file ++ " for build plan.")
    loadBuildPlanYAML yaml_file
  handleIOError :: IOException -> Maybe ErrorMsg
  handleIOError e | IOE.isDoesNotExistError e = Just $ makeErrorMsg e (yaml_file ++ " not found.")
                  | IOE.isPermissionError e = Just $ makeErrorMsg e ("you cannot open " ++ yaml_file ++ ".")
                  | otherwise = Just $ makeErrorMsg e ("some error.")
  makeErrorMsg exception body = "Loading build plan for package resolver '" ++ resolver ++ "' failed: " ++ body ++ "\n" ++ show exception

loadBuildPlan_stackageNetwork :: BuildPlanManager -> Resolver -> IO (Either ErrorMsg BuildPlan)
loadBuildPlan_stackageNetwork man resolver = either (return . Left) (uncurry impl_network) $ checkArgs where
  checkArgs = do
    http_man <- maybe (Left ("It is not allowed to access network.")) Right $ manHttpManager man
    presolver <- maybe (Left ("Unknown resolver: " ++ resolver)) Right $ parseResolverString resolver
    return (http_man, presolver)
  impl_network http_man presolver = do
    m_disam <- readIORef $ manDisambiguator man
    (eret, got_disam) <- loadBuildPlanYAMLForResolver http_man m_disam presolver
    writeIORef (manDisambiguator man) got_disam
    return $ (parseBuildPlanYAML . BSL.toStrict) =<< eret

parseBuildPlanYAML :: BS.ByteString -> Either ErrorMsg BuildPlan
parseBuildPlanYAML = either (Left . toErrorMsg) Right  . Yaml.decodeEither' where
  toErrorMsg parse_exception = "Error while parsing BuildPlan YAML: " ++ show parse_exception

-- | Load a 'BuildPlan' from a file.
loadBuildPlanYAML :: FilePath -> IO (Either ErrorMsg BuildPlan)
loadBuildPlanYAML yaml_file = parseBuildPlanYAML <$> BS.readFile yaml_file where -- TODO: make it memory-efficient!

packageVersion :: BuildPlan -> PackageName -> Maybe Version
packageVersion (BuildPlan bp_map) name = HM.lookup name bp_map

-- | Parse a version text. There must not be any trailing characters
-- after a valid version text.
parseVersionText :: Text -> Maybe Version
parseVersionText = extractResult . (readP_to_S parseVersion) . unpack where
  extractResult = listToMaybe . map fst . filter (\pair -> snd pair == "")

_setDisambiguator :: BuildPlanManager -> Maybe Disambiguator -> IO ()
_setDisambiguator bp_man = writeIORef (manDisambiguator bp_man)
