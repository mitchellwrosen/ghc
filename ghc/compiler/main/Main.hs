{-# OPTIONS -W -fno-warn-incomplete-patterns #-}
-----------------------------------------------------------------------------
-- $Id: Main.hs,v 1.4 2000/10/11 15:26:18 simonmar Exp $
--
-- GHC Driver program
--
-- (c) Simon Marlow 2000
--
-----------------------------------------------------------------------------

-- with path so that ghc -M can find config.h
#include "../includes/config.h"

module Main (main) where

#include "HsVersions.h"

import DriverPipeline
import DriverState
import DriverFlags
import DriverMkDepend
import DriverUtil
import TmpFiles
import Config
import Util
import Panic

import Concurrent
#ifndef mingw32_TARGET_OS
import Posix
#endif
import Directory
import IOExts
import Exception
import Dynamic

import IO
import Monad
import List
import System
import Maybe

-----------------------------------------------------------------------------
-- Changes:

-- * -fglasgow-exts NO LONGER IMPLIES -package lang!!!  (-fglasgow-exts is a
--   dynamic flag whereas -package is a static flag.)

-----------------------------------------------------------------------------
-- ToDo:

-- new mkdependHS doesn't support all the options that the old one did (-X et al.)
-- time commands when run with -v
-- split marker
-- mkDLL
-- java generation
-- user ways
-- Win32 support: proper signal handling
-- make sure OPTIONS in .hs file propogate to .hc file if -C or -keep-hc-file-too
-- reading the package configuration file is too slow
-- -H, -K, -Rghc-timing
-- hi-diffs

-----------------------------------------------------------------------------
-- Differences vs. old driver:

-- No more "Enter your Haskell program, end with ^D (on a line of its own):"
-- consistency checking removed (may do this properly later)
-- removed -noC
-- no hi diffs (could be added later)
-- no -Ofile

-----------------------------------------------------------------------------
-- Main loop

main =
  -- all error messages are propagated as exceptions
  handleDyn (\dyn -> case dyn of
			  PhaseFailed _phase code -> exitWith code
			  Interrupted -> exitWith (ExitFailure 1)
			  _ -> do hPutStrLn stderr (show (dyn :: BarfKind))
			          exitWith (ExitFailure 1)
	      ) $ do

   -- make sure we clean up after ourselves
   later (do  forget_it <- readIORef keep_tmp_files
	      unless forget_it $ do
	      verb <- readIORef verbose
	      cleanTempFiles verb
     ) $ do
	-- exceptions will be blocked while we clean the temporary files,
	-- so there shouldn't be any difficulty if we receive further
	-- signals.

	-- install signal handlers
   main_thread <- myThreadId

#ifndef mingw32_TARGET_OS
   let sig_handler = Catch (throwTo main_thread 
				(DynException (toDyn Interrupted)))
   installHandler sigQUIT sig_handler Nothing 
   installHandler sigINT  sig_handler Nothing
#endif

   pgm    <- getProgName
   writeIORef prog_name pgm

   argv   <- getArgs

	-- grab any -B options from the command line first
   argv'  <- setTopDir argv
   top_dir <- readIORef topDir

   let installed s = top_dir ++ s
       inplace s   = top_dir ++ '/':cCURRENT_DIR ++ '/':s

       installed_pkgconfig = installed ("package.conf")
       inplace_pkgconfig   = inplace (cGHC_DRIVER_DIR ++ "/package.conf.inplace")

	-- discover whether we're running in a build tree or in an installation,
	-- by looking for the package configuration file.
   am_installed <- doesFileExist installed_pkgconfig

   if am_installed
	then writeIORef path_package_config installed_pkgconfig
	else do am_inplace <- doesFileExist inplace_pkgconfig
	        if am_inplace
		    then writeIORef path_package_config inplace_pkgconfig
		    else throwDyn (OtherError "can't find package.conf")

	-- set the location of our various files
   if am_installed
	then do writeIORef path_usage (installed "ghc-usage.txt")
		writeIORef pgm_L (installed "unlit")
		writeIORef pgm_C (installed "hsc")
		writeIORef pgm_m (installed "ghc-asm")
		writeIORef pgm_s (installed "ghc-split")

	else do writeIORef path_usage (inplace (cGHC_DRIVER_DIR ++ "/ghc-usage.txt"))
		writeIORef pgm_L (inplace cGHC_UNLIT)
		writeIORef pgm_C (inplace cGHC_HSC)
		writeIORef pgm_m (inplace cGHC_MANGLER)
		writeIORef pgm_s (inplace cGHC_SPLIT)

	-- read the package configuration
   conf_file <- readIORef path_package_config
   contents <- readFile conf_file
   writeIORef package_details (read contents)

	-- find the phase to stop after (i.e. -E, -C, -c, -S flags)
   (flags2, mode, stop_flag) <- getGhcMode argv'
   writeIORef v_GhcMode mode

	-- process all the other arguments, and get the source files
   non_static <- processArgs static_flags flags2 []

	-- find the build tag, and re-process the build-specific options
   more_opts <- findBuildTag
   _ <- processArgs static_flags more_opts []
 
	-- give the static flags to hsc
   build_hsc_opts

	-- the rest of the arguments are "dynamic"
   srcs <- processArgs dynamic_flags non_static []

    	-- complain about any unknown flags
   let unknown_flags = [ f | ('-':f) <- srcs ]
   mapM unknownFlagErr unknown_flags

	-- get the -v flag
   verb <- readIORef verbose

   when verb (do hPutStr stderr "Glasgow Haskell Compiler, Version "
 	         hPutStr stderr version_str
	         hPutStr stderr ", for Haskell 98, compiled by GHC version "
	         hPutStrLn stderr booter_version)

   when verb (hPutStrLn stderr ("Using package config file: " ++ conf_file))

	-- mkdependHS is special
   when (mode == DoMkDependHS) beginMkDependHS

	-- make is special
   when (mode == DoMake) beginMake

	-- for each source file, find which phases to run
   pipelines <- mapM (genPipeline mode stop_flag) srcs
   let src_pipelines = zip srcs pipelines

   o_file <- readIORef output_file
   if isJust o_file && mode /= DoLink && length srcs > 1
	then throwDyn (UsageError "can't apply -o option to multiple source files")
	else do

   if null srcs then throwDyn (UsageError "no input files") else do

	-- save the flag state, because this could be modified by OPTIONS pragmas
	-- during the compilation, and we'll need to restore it before starting
	-- the next compilation.
   saved_driver_state <- readIORef driver_state

   let compileFile (src, phases) = do
	  r <- runPipeline phases src (mode==DoLink) True
	  writeIORef driver_state saved_driver_state
	  return r

   o_files <- mapM compileFile src_pipelines

   when (mode == DoMkDependHS) endMkDependHS

   when (mode == DoLink) (doLink o_files)

	-- grab the last -B option on the command line, and
	-- set topDir to its value.
setTopDir :: [String] -> IO [String]
setTopDir args = do
  let (minusbs, others) = partition (prefixMatch "-B") args
  (case minusbs of
    []   -> writeIORef topDir clibdir
    some -> writeIORef topDir (drop 2 (last some)))
  return others

beginMake = panic "`ghc --make' unimplemented"

-----------------------------------------------------------------------------
-- compatibility code

#if __GLASGOW_HASKELL__ <= 408
catchJust = catchIO
ioErrors  = justIoErrors
throwTo   = raiseInThread
#endif

#ifdef mingw32_TARGET_OS
foreign import "_getpid" getProcessID :: IO Int 
#endif
