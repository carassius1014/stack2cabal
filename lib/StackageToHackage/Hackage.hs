{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

-- | A simplistic model of cabal multi-package files and convertors from Stackage.
module StackageToHackage.Hackage
    ( Freeze(..)
    , Project(..)
    , printFreeze
    , printProject
    , stackToCabal
    )
where

import StackageToHackage.Stackage ( localDirs, unroll, mergeResolvers )
import StackageToHackage.Stackage.Types
    ( Resolver(Resolver, compiler, deps, flags)
    , PkgId(unPkgId)
    , GhcFlags
    , GhcOptions(GhcOptions)
    , PackageGhcOpts(PackageGhcOpts)
    , Flags(..)
    , Dep(..)
    , Git(..)
    , Ghc(Ghc)
    , Stack(ghcOptions)
    )
import StackageToHackage.Hpack (hpackInput, execHpack)
import StackageToHackage.Hackage.Types
    ( Constraint(..), Freeze(..), Project(..) )

import Control.Exception (throwIO)
import Control.Monad (forM, when, void)
import Control.Monad.Catch (handleIOError)
import Data.Hourglass (timePrint, ISO8601_DateAndTime(..), Elapsed)
import Data.List (nub, sort, sortOn)
import Data.List.Extra (nubOrd, nubOrdOn)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Maybe (fromMaybe, mapMaybe, catMaybes)
import Data.Text (Text)
import Distribution.PackageDescription.Parsec (readGenericPackageDescription)
import Distribution.Pretty (prettyShow)
import Distribution.Types.GenericPackageDescription
    (GenericPackageDescription(..))
import Distribution.Types.PackageDescription (PackageDescription(..))
import Distribution.Types.PackageId (PackageIdentifier(..))
import Distribution.Types.PackageName (PackageName, unPackageName)
import Distribution.Verbosity (silent)
import Safe (headMay)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.FilePattern.Directory (getDirectoryFiles)
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
    (withCreateProcess, proc, waitForProcess, StdStream(..), CreateProcess(..))

import qualified Data.List.NonEmpty as NEL
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import System.Directory (doesFileExist)


-- | Converts a stack.yaml (and list of local packages) to cabal.project and
-- cabal.project.freeze.
stackToCabal :: Bool     -- ^ whether to inspect remotes
             -> Bool     -- ^ whether to run hpack
             -> FilePath
             -> Stack
             -> IO (Project, Freeze)
stackToCabal inspectRemotes runHpack dir stack = do
    resolvers <- unroll dir stack
    let resolver = foldr1 mergeResolvers resolvers
        project = genProject stack resolver
    localPkgs <-
        fmap catMaybes
        . traverse (\f -> getPackageIdent (dir </> f))
        . NEL.toList
        . pkgs
        $ project
    remotePkgs <- if inspectRemotes
        then getRemotePkgs (srcs project) runHpack
        else pure []
    let ignore = sort . nub . fmap pkgName $ (localPkgs ++ remotePkgs)
    let freeze = genFreeze resolver ignore
    pure (project, freeze)


printProject :: Bool           -- ^ whether to pin GHC
             -> Maybe Elapsed  -- ^ hackage index date to pin
             -> Project
             -> Maybe Text
             -> IO Text
printProject pinGHC indexDate (Project (Ghc ghc) pkgs srcs ghcOpts) hack = do
    ghcOpts' <- printGhcOpts ghcOpts
    pure $ T.concat
        $ ["-- Generated by stackage-to-hackage\n\n"]
        <> withHackageIndex
        <> withCompiler
        <> [ "packages:\n    ", packages, "\n\n", sources
           , "\n", "allow-older: *\n", "allow-newer: *\n"
           ]
        <> ghcOpts'
        <> verbatim hack
  where
    withHackageIndex :: [Text]
    withHackageIndex
        | (Just utc) <- indexDate = ["index-state: ", printUTC utc, "\n\n"]
        | otherwise = []
      where
        printUTC :: Elapsed -> Text
        printUTC = T.pack . timePrint ISO8601_DateAndTime

    withCompiler :: [Text]
    withCompiler
        | pinGHC = ["with-compiler: ", ghc, "\n\n"]
        | otherwise = []

    verbatim :: Maybe Text -> [Text]
    verbatim Nothing = []
    verbatim (Just txt) = ["\n-- Verbatim\n", txt, "\n"]

    packages :: Text
    packages = T.intercalate "\n  , " (T.pack . addTrailingPathSeparator' <$> NEL.toList pkgs)
      where
        addTrailingPathSeparator' :: FilePath -> FilePath
        addTrailingPathSeparator' x =
            if hasTrailingPathSeparator' x then x else x ++ ['/']

        hasTrailingPathSeparator' :: FilePath -> Bool
        hasTrailingPathSeparator' "" = False
        hasTrailingPathSeparator' x = last x == '/'

    sources :: Text
    sources = T.intercalate "\n" (source =<< srcs)

    source :: Git -> [Text]
    source Git { repo, commit, subdirs } =
        let base = T.concat
                [ "source-repository-package\n    ", "type: git\n    ", "location: "
                , repo, "\n    ", "tag: ", commit, "\n"
                ]
        in case sort subdirs of
            [] -> [base]
            (x:xs) -> [T.concat $ [base, "    subdir: ", x]
                      ++ (("\n            " <>) <$> xs)
                      ++ ["\n"]]

    -- Get the ghc options. This requires IO, because we have to figure out
    -- the local package names.
    printGhcOpts :: GhcOptions -> IO [GhcFlags]
    printGhcOpts (GhcOptions locals _ everything (PackageGhcOpts packagesGhcOpts)) = do
        -- locals are basically pkgs since cabal-install-3.4.0.0
        localsPrint <- case locals of
            Just x -> fmap concat $ forM pkgs $ \pkg -> do
                name <- fmap (unPackageName . pkgName)
                    <$> getPackageIdent pkg
                pure $ maybe []
                    (\n -> if M.member n $ M.mapKeys
                            (unPackageName . pkgName . unPkgId)
                            packagesGhcOpts
                        then []
                        else [ "\npackage ", T.pack n, "\n    ", "ghc-options: ", x, "\n" ]
                    )
                    name
            Nothing -> pure []
        let everythingPrint = case everything of
                Just x -> ["\npackage ", "*", "\n    ", "ghc-options: ", x, "\n"]
                Nothing -> []
        let pkgSpecificPrint = M.foldrWithKey
                (\k a b -> [ "\npackage ", T.pack . unPackageName . pkgName . unPkgId $ k
                    , "\n    "
                    , "ghc-options: "
                    , a
                    , "\n"
                    ]
                    <> b) [] packagesGhcOpts
        pure (everythingPrint <> localsPrint <> pkgSpecificPrint)


genProject :: Stack -> Resolver -> Project
genProject stack Resolver { compiler, deps } = Project
    (fromMaybe (Ghc "ghc") compiler)
    (localDirs stack `appendList` localDeps deps)
    (sortOn repo $ nubOrd $ mapMaybe pickGit deps)
    (ghcOptions stack)
  where
    pickGit :: Dep -> Maybe Git
    pickGit (Hackage _) = Nothing
    pickGit (LocalDep _) = Nothing
    pickGit (SourceDep g) = Just g

    localDeps :: [Dep] -> [FilePath]
    localDeps = mapMaybe fromLocalDeps

    fromLocalDeps :: Dep -> Maybe FilePath
    fromLocalDeps (Hackage _) = Nothing
    fromLocalDeps (SourceDep _) = Nothing
    fromLocalDeps (LocalDep d) = Just d

    appendList :: NonEmpty a -> [a] -> NonEmpty a
    appendList (x :| xs) ys = x :| (xs ++ ys)


printFreeze :: Freeze -> Text
printFreeze (Freeze constraints) = T.concat
    ["constraints: ", printConstraints, "\n"]
  where
    spacing :: Text
    spacing = ",\n             "

    printConstraints :: Text
    printConstraints = T.intercalate spacing . fmap printConstraint $ constraints

    printConstraint :: Constraint -> Text
    printConstraint (VersionPin pkg) =
        let name = (T.pack . unPackageName . pkgName $ pkg)
            ver = (T.pack . prettyShow . pkgVersion $ pkg)
        in T.concat ["any.", name, " ==", ver]
    printConstraint (FlagSetting name flags)
        = T.concat [name, " ", custom flags]

    custom :: M.Map Text Bool -> Text
    custom (M.toList -> lst) = T.intercalate " " (renderFlag <$> lst)

    renderFlag :: (Text, Bool) -> Text
    renderFlag (name, True) = "+" <> name
    renderFlag (name, False) = "-" <> name


genFreeze :: Resolver
          -> [PackageName]       -- ^ ignore these (local packages)
          -> Freeze
genFreeze Resolver { deps, flags } ignore =
    let pkgs = filter noSelfs $ unPkgId <$> mapMaybe pick deps
        uniqpkgs = nubOrdOn pkgName pkgs
    in Freeze (toConstraints uniqpkgs flags)
  where
    pick :: Dep -> Maybe PkgId
    pick (Hackage p) = Just p
    pick (SourceDep _) = Nothing
    pick (LocalDep _) = Nothing

    noSelfs :: PackageIdentifier -> Bool
    noSelfs (pkgName -> n) = n `notElem` ignore

    toConstraints :: [PackageIdentifier] -> Flags -> [Constraint]
    toConstraints deps' (Flags flags') =
        let cdeps = fmap VersionPin deps'
            cflags = M.elems $ M.mapWithKey FlagSetting flags'
        in sort (cdeps ++ cflags)


-- | Acquire all package identifiers from a list of subdirs
-- of a git repository.
getRemotePkg :: Git -> Bool -> IO [PackageIdentifier]
getRemotePkg git@(Git (T.unpack -> repo) (T.unpack -> commit) (fmap T.unpack -> subdirs)) runHpack
    = withSystemTempDirectory "stack2cabal" $ \dir ->
          handleIOError
                (\_ -> hPutStrLn stderr
                    ("Warning: failed to resolve remote .cabal files of: " <> show git)
                    >> pure []
                ) $ do
                    callProcess "git" ["clone", repo, dir]
                    callProcess "git" ["-C", dir, "reset", "--hard", commit]
                    case subdirs of
                        [] -> do
                            when runHpack $ do
                              b <- doesFileExist (hpackInput dir)
                              when b $ void $ execHpack dir
                            (Just pid) <- getPackageIdent dir
                            pure [pid]
                        _ ->
                            forM subdirs $ \subdir -> do
                                let fullDir =  dir </> subdir
                                when runHpack $ do
                                  b <- doesFileExist (hpackInput fullDir)
                                  when b $ void $ execHpack fullDir
                                (Just pid) <- getPackageIdent fullDir
                                pure pid
  where
    callProcess :: FilePath -> [String] -> IO ()
    callProcess cmd args = do
        exit_code <- withCreateProcess (proc cmd args)
            { delegate_ctlc = True
            , std_out = UseHandle stderr
            } $ \_ _ _ p -> waitForProcess p
        case exit_code of
            ExitSuccess -> return ()
            ExitFailure r ->
                throwIO
                    . userError
                    $ ("Process \"" <> cmd <> "\" failed with: " <> show r)


-- | Get package identifier from project directory.
getPackageIdent :: FilePath  -- ^ absolute path to project repository
                -> IO (Maybe PackageIdentifier)
getPackageIdent dir =
    handleIOError
        (\_ -> hPutStrLn stderr ("Warning: failed to resolve .cabal file in " <> dir)
            >> pure Nothing
        ) $ do
            cabalFile <- headMay <$> getDirectoryFiles dir ["*.cabal"]
            forM cabalFile $ \f ->
                package . packageDescription
                    <$> readGenericPackageDescription silent (dir </> f)


-- | Get all remote VCS packages.
getRemotePkgs :: [Git] -> Bool -> IO [PackageIdentifier]
getRemotePkgs srcs runHpack = fmap concat $ forM srcs $ \src -> getRemotePkg src runHpack
