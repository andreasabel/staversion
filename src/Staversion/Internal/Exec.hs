-- |
-- Module: Staversion.Internal.Exec
-- Description: executable
-- Maintainer: Toshio Ito <debug.ito@gmail.com>
--
-- __This is an internal module. End-users should not use it.__
module Staversion.Internal.Exec
       ( main,
         processCommand
       ) where

import Data.Function (on)
import Data.List (groupBy)
import Data.Text (unpack)
import System.FilePath ((</>), (<.>))

import Staversion.Internal.BuildPlan
  ( BuildPlan, loadBuildPlanYAML, packageVersion
  )
import Staversion.Internal.Command
  ( parseCommandArgs,
    Command(..)
  )
import Staversion.Internal.Query
  ( Query(..), Result(..), PackageSource(..), resultVersionsFromList
  )

main :: IO ()
main = do
  comm <- parseCommandArgs
  (putStrLn . show) =<< (processCommand comm)

processCommand :: Command -> IO [Result]
processCommand comm = fmap concat $ mapM processQueriesIn $ commSources comm where
  processQueriesIn source = do
    build_plan <- loadBuildPlan comm source
    return $ map (searchVersion source build_plan) $ commQueries comm

-- | TODO: implement error handling
loadBuildPlan ::  Command -> PackageSource -> IO BuildPlan
loadBuildPlan comm (SourceStackage resolver) = loadBuildPlanYAML yaml_file where
  yaml_file = commBuildPlanDir comm </> resolver <.> "yaml"

searchVersion :: PackageSource -> BuildPlan -> Query -> Result
searchVersion source build_plan query@(QueryName package_name) =
  Result { resultIn = source,
           resultFor = query,
           resultVersions = Right $ resultVersionsFromList [(package_name, packageVersion build_plan package_name)]
         }
