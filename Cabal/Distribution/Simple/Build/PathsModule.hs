-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Build.Macros
-- Copyright   :  Isaac Jones 2003-2005,
--                Ross Paterson 2006,
--                Duncan Coutts 2007-2008
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- Generating the Paths_pkgname module.
--
-- This is a module that Cabal generates for the benefit of packages. It
-- enables them to find their version number and find any installed data files
-- at runtime. This code should probably be split off into another module.
--
module Distribution.Simple.Build.PathsModule (
    generate, pkgPathEnvVar
  ) where

import Distribution.System
         ( OS(Windows), buildOS, Arch(..), buildArch )
import Distribution.Simple.Compiler
         ( CompilerFlavor(..), compilerFlavor, compilerVersion )
import Distribution.Package
         ( packageId, packageName, packageVersion )
import Distribution.PackageDescription
         ( PackageDescription(..), hasLibs )
import Distribution.Simple.LocalBuildInfo
         ( LocalBuildInfo(..), InstallDirs(..)
         , absoluteInstallDirs, prefixRelativeInstallDirs )
import Distribution.Simple.Setup ( CopyDest(NoCopyDest) )
import Distribution.Simple.BuildPaths
         ( autogenModuleName )
import Distribution.Simple.Utils
         ( shortRelativePath )
import Distribution.Text
         ( display )
import Distribution.Version
         ( Version(..), orLaterVersion, withinRange )

import System.FilePath
         ( pathSeparator )
import Data.Maybe
         ( fromJust, isNothing )

-- ------------------------------------------------------------
-- * Building Paths_<pkg>.hs
-- ------------------------------------------------------------

generate :: PackageDescription -> LocalBuildInfo -> String
generate pkg_descr lbi =
   let pragmas
        | absolute = ""
        | supports_language_pragma =
          "{-# LANGUAGE ForeignFunctionInterface #-}\n"
        | otherwise =
          "{-# OPTIONS_GHC -fffi #-}\n"++
          "{-# OPTIONS_JHC -fffi #-}\n"

       foreign_imports
        | absolute = ""
        | otherwise =
          "import Foreign\n"++
          "import Foreign.C\n"

       reloc_imports
        | reloc =
          "import System.Environment (getExecutablePath)\n"
        | otherwise = ""

       header =
        pragmas++
        "module " ++ display paths_modulename ++ " (\n"++
        "    version,\n"++
        "    getBinDir, getLibDir, getDataDir, getLibexecDir,\n"++
        "    getDataFileName, getSysconfDir\n"++
        "  ) where\n"++
        "\n"++
        foreign_imports++
        "import qualified Control.Exception as Exception\n"++
        "import Data.Version (Version(..))\n"++
        "import System.Environment (getEnv)\n"++
        reloc_imports ++
        "import Prelude\n"++
        "\n"++
        "catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a\n"++
        "catchIO = Exception.catch\n" ++
        "\n"++
        "version :: Version"++
        "\nversion = Version " ++ show branch ++ " " ++ show tags
          where Version branch tags = packageVersion pkg_descr

       body
        | reloc =
          "\n\nbindirrel :: FilePath\n" ++
          "bindirrel = " ++ show flat_bindirreloc ++
          "\n"++
          "\ngetBinDir, getLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath\n"++
          "getBinDir = "++mkGetEnvOrReloc "bindir" flat_bindirreloc++"\n"++
          "getLibDir = "++mkGetEnvOrReloc "libdir" flat_libdirreloc++"\n"++
          "getDataDir = "++mkGetEnvOrReloc "datadir" flat_datadirreloc++"\n"++
          "getLibexecDir = "++mkGetEnvOrReloc "libexecdir" flat_libexecdirreloc++"\n"++
          "getSysconfDir = "++mkGetEnvOrReloc "sysconfdir" flat_sysconfdirreloc++"\n"++
          "\n"++
          "getDataFileName :: FilePath -> IO FilePath\n"++
          "getDataFileName name = do\n"++
          "  dir <- getDataDir\n"++
          "  return (dir `joinFileName` name)\n"++
          "\n"++
          get_prefix_reloc_stuff++
          "\n"++
          filename_stuff
        | absolute =
          "\nbindir, libdir, datadir, libexecdir, sysconfdir :: FilePath\n"++
          "\nbindir     = " ++ show flat_bindir ++
          "\nlibdir     = " ++ show flat_libdir ++
          "\ndatadir    = " ++ show flat_datadir ++
          "\nlibexecdir = " ++ show flat_libexecdir ++
          "\nsysconfdir = " ++ show flat_sysconfdir ++
          "\n"++
          "\ngetBinDir, getLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath\n"++
          "getBinDir = "++mkGetEnvOr "bindir" "return bindir"++"\n"++
          "getLibDir = "++mkGetEnvOr "libdir" "return libdir"++"\n"++
          "getDataDir = "++mkGetEnvOr "datadir" "return datadir"++"\n"++
          "getLibexecDir = "++mkGetEnvOr "libexecdir" "return libexecdir"++"\n"++
          "getSysconfDir = "++mkGetEnvOr "sysconfdir" "return sysconfdir"++"\n"++
          "\n"++
          "getDataFileName :: FilePath -> IO FilePath\n"++
          "getDataFileName name = do\n"++
          "  dir <- getDataDir\n"++
          "  return (dir ++ "++path_sep++" ++ name)\n"
        | otherwise =
          "\nprefix, bindirrel :: FilePath" ++
          "\nprefix        = " ++ show flat_prefix ++
          "\nbindirrel     = " ++ show (fromJust flat_bindirrel) ++
          "\n\n"++
          "getBinDir :: IO FilePath\n"++
          "getBinDir = getPrefixDirRel bindirrel\n\n"++
          "getLibDir :: IO FilePath\n"++
          "getLibDir = "++mkGetDir flat_libdir flat_libdirrel++"\n\n"++
          "getDataDir :: IO FilePath\n"++
          "getDataDir =  "++ mkGetEnvOr "datadir"
                              (mkGetDir flat_datadir flat_datadirrel)++"\n\n"++
          "getLibexecDir :: IO FilePath\n"++
          "getLibexecDir = "++mkGetDir flat_libexecdir flat_libexecdirrel++"\n\n"++
          "getSysconfDir :: IO FilePath\n"++
          "getSysconfDir = "++mkGetDir flat_sysconfdir flat_sysconfdirrel++"\n\n"++
          "getDataFileName :: FilePath -> IO FilePath\n"++
          "getDataFileName name = do\n"++
          "  dir <- getDataDir\n"++
          "  return (dir `joinFileName` name)\n"++
          "\n"++
          get_prefix_stuff++
          "\n"++
          filename_stuff
   in header++body

 where
        InstallDirs {
          prefix     = flat_prefix,
          bindir     = flat_bindir,
          libdir     = flat_libdir,
          datadir    = flat_datadir,
          libexecdir = flat_libexecdir,
          sysconfdir = flat_sysconfdir
        } = absoluteInstallDirs pkg_descr lbi NoCopyDest
        InstallDirs {
          bindir     = flat_bindirrel,
          libdir     = flat_libdirrel,
          datadir    = flat_datadirrel,
          libexecdir = flat_libexecdirrel,
          sysconfdir = flat_sysconfdirrel
        } = prefixRelativeInstallDirs (packageId pkg_descr) lbi

        flat_bindirreloc = shortRelativePath flat_prefix flat_bindir
        flat_libdirreloc = shortRelativePath flat_prefix flat_libdir
        flat_datadirreloc = shortRelativePath flat_prefix flat_datadir
        flat_libexecdirreloc = shortRelativePath flat_prefix flat_libexecdir
        flat_sysconfdirreloc = shortRelativePath flat_prefix flat_sysconfdir

        mkGetDir _   (Just dirrel) = "getPrefixDirRel " ++ show dirrel
        mkGetDir dir Nothing       = "return " ++ show dir

        mkGetEnvOrReloc var dirrel = "catchIO (getEnv \""++var'++"\")" ++
                                     " (\\_ -> getPrefixDirReloc \"" ++ dirrel ++
                                     "\")"
          where var' = pkgPathEnvVar pkg_descr var

        mkGetEnvOr var expr = "catchIO (getEnv \""++var'++"\")"++
                              " (\\_ -> "++expr++")"
          where var' = pkgPathEnvVar pkg_descr var

        -- In several cases we cannot make relocatable installations
        absolute =
             hasLibs pkg_descr        -- we can only make progs relocatable
          || isNothing flat_bindirrel -- if the bin dir is an absolute path
          || not (supportsRelocatableProgs (compilerFlavor (compiler lbi)))

        reloc = relocatable lbi

        supportsRelocatableProgs GHC  = case buildOS of
                           Windows   -> True
                           _         -> False
        supportsRelocatableProgs GHCJS = case buildOS of
                           Windows   -> True
                           _         -> False
        supportsRelocatableProgs _    = False

        paths_modulename = autogenModuleName pkg_descr

        get_prefix_stuff = get_prefix_win32 buildArch

        path_sep = show [pathSeparator]

        supports_language_pragma =
          (compilerFlavor (compiler lbi) == GHC &&
            (compilerVersion (compiler lbi)
              `withinRange` orLaterVersion (Version [6,6,1] []))) ||
           compilerFlavor (compiler lbi) == GHCJS

-- | Generates the name of the environment variable controlling the path
-- component of interest.
pkgPathEnvVar :: PackageDescription
              -> String     -- ^ path component; one of \"bindir\", \"libdir\",
                            -- \"datadir\", \"libexecdir\", or \"sysconfdir\"
              -> String     -- ^ environment variable name
pkgPathEnvVar pkg_descr var =
    showPkgName (packageName pkg_descr) ++ "_" ++ var
    where
        showPkgName = map fixchar . display
        fixchar '-' = '_'
        fixchar c   = c

get_prefix_reloc_stuff :: String
get_prefix_reloc_stuff =
  "getPrefixDirReloc :: FilePath -> IO FilePath\n"++
  "getPrefixDirReloc dirRel = do\n"++
  "  exePath <- getExecutablePath\n"++
  "  let (bindir,_) = splitFileName exePath\n"++
  "  return ((bindir `minusFileName` bindirrel) `joinFileName` dirRel)\n"

get_prefix_win32 :: Arch -> String
get_prefix_win32 arch =
  "getPrefixDirRel :: FilePath -> IO FilePath\n"++
  "getPrefixDirRel dirRel = try_size 2048 -- plenty, PATH_MAX is 512 under Win32.\n"++
  "  where\n"++
  "    try_size size = allocaArray (fromIntegral size) $ \\buf -> do\n"++
  "        ret <- c_GetModuleFileName nullPtr buf size\n"++
  "        case ret of\n"++
  "          0 -> return (prefix `joinFileName` dirRel)\n"++
  "          _ | ret < size -> do\n"++
  "              exePath <- peekCWString buf\n"++
  "              let (bindir,_) = splitFileName exePath\n"++
  "              return ((bindir `minusFileName` bindirrel) `joinFileName` dirRel)\n"++
  "            | otherwise  -> try_size (size * 2)\n"++
  "\n"++
  "foreign import " ++ cconv ++ " unsafe \"windows.h GetModuleFileNameW\"\n"++
  "  c_GetModuleFileName :: Ptr () -> CWString -> Int32 -> IO Int32\n"
    where cconv = case arch of
                  I386 -> "stdcall"
                  X86_64 -> "ccall"
                  _ -> error "win32 supported only with I386, X86_64"

filename_stuff :: String
filename_stuff =
  "minusFileName :: FilePath -> String -> FilePath\n"++
  "minusFileName dir \"\"     = dir\n"++
  "minusFileName dir \".\"    = dir\n"++
  "minusFileName dir suffix =\n"++
  "  minusFileName (fst (splitFileName dir)) (fst (splitFileName suffix))\n"++
  "\n"++
  "joinFileName :: String -> String -> FilePath\n"++
  "joinFileName \"\"  fname = fname\n"++
  "joinFileName \".\" fname = fname\n"++
  "joinFileName dir \"\"    = dir\n"++
  "joinFileName dir fname\n"++
  "  | isPathSeparator (last dir) = dir++fname\n"++
  "  | otherwise                  = dir++pathSeparator:fname\n"++
  "\n"++
  "splitFileName :: FilePath -> (String, String)\n"++
  "splitFileName p = (reverse (path2++drive), reverse fname)\n"++
  "  where\n"++
  "    (path,drive) = case p of\n"++
  "       (c:':':p') -> (reverse p',[':',c])\n"++
  "       _          -> (reverse p ,\"\")\n"++
  "    (fname,path1) = break isPathSeparator path\n"++
  "    path2 = case path1 of\n"++
  "      []                           -> \".\"\n"++
  "      [_]                          -> path1   -- don't remove the trailing slash if \n"++
  "                                              -- there is only one character\n"++
  "      (c:path') | isPathSeparator c -> path'\n"++
  "      _                             -> path1\n"++
  "\n"++
  "pathSeparator :: Char\n"++
  (case buildOS of
       Windows   -> "pathSeparator = '\\\\'\n"
       _         -> "pathSeparator = '/'\n") ++
  "\n"++
  "isPathSeparator :: Char -> Bool\n"++
  (case buildOS of
       Windows   -> "isPathSeparator c = c == '/' || c == '\\\\'\n"
       _         -> "isPathSeparator c = c == '/'\n")
