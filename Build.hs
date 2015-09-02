{-# LANGUAGE GeneralizedNewtypeDeriving #-}
import System.IO.Unsafe
import System.Exit
import Control.Concurrent.MVar
import Development.Shake
import Development.Shake.Util
import Development.Shake.Config
import Development.Shake.Classes
import Development.Shake.FilePath

newtype OcamlOrdOracle = OcamlOrdOracle String
                       deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
newtype OcamlCmdLineOracle = OcamlCmdLineOracle String
                           deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
newtype CCmdLineOracle = CCmdLineOracle String
                       deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
newtype GitDescribeOracle = GitDescribeOracle ()
                          deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
data CM = CMO | CMI

outdir = "build"
mudir = "/home/malc/x/rcs/git/mupdf"
inOutDir s = outdir </> s

ocamlc = "ocamlc.opt"
ocamldep = "ocamldep.opt"
ocamlflags = "-warn-error +a -w +a -g -safe-string"
ocamlflagstbl = [("main.cmo", ("-I +lablGL", "sed -f pp.sed"))
                ,("config.cmo", ("-I +lablGL", ""))
                ,("wsi.cmo", ("-I le", ""))
                ]
cflags = "-Wall -Werror -D_GNU_SOURCE -O\
         \ -g -std=c99 -pedantic-errors\
         \ -Wunused-parameter -Wsign-compare -Wshadow"
cflagstbl =
  [("link.o"
   ,"-I " ++ mudir ++ "/include -I "
    ++ mudir ++ "/thirdparty/freetype/include -Wextra")
  ]
cclib = "-lmupdf -lz -lfreetype -ljpeg \
        \-ljbig2dec -lopenjpeg -lmujs \
        \-lpthread -L" ++ mudir ++ "/build/native -lcrypto"

getincludes :: [String] -> [String]
getincludes [] = []
getincludes ("-I":arg:tl) = arg : getincludes tl
getincludes (_:tl) = getincludes tl

isabsinc :: String -> Bool
isabsinc [] = False
isabsinc (hd:tl) = hd == '+' || hd == '/'

fixincludes [] = []
fixincludes ("-I":d:tl)
  | isabsinc d = "-I":d:fixincludes tl
  | otherwise = "-I":inOutDir d:fixincludes tl
fixincludes (e:tl) = e:fixincludes tl

ocamlKey key =
  case lookup key ocamlflagstbl of
  Nothing -> (ocamlc, ocamlflags, [])
  Just (f, []) -> (ocamlc, ocamlflags ++ " " ++ f, [])
  Just (f, pp) -> (ocamlc, ocamlflags ++ " " ++ f, ["-pp", pp])

cKey key =
  case lookup key cflagstbl of
  Nothing -> cflags
  Just f -> f ++ " " ++ cflags

fixppfile :: String -> [String] -> [String]
fixppfile s ("File":_:tl) = ("File \"" ++ s ++ "\","):tl
fixppfile _ l = l

fixpp :: String -> String -> String
fixpp r s =
  unlines $ unwords (fixppfile r $ words hd) : tl
  where hd:tl = lines s

cm' outdir t oracle ordoracle =
  target `op` \out -> do
    let key = dropDirectory1 out
    let src' = key -<.> suffix
    let src = if src' == "help.ml" then inOutDir src' else src'
    need [src]
    (comp, flags, ppflags) <- oracle $ OcamlCmdLineOracle key
    let flagl = words flags
    let incs = unwords ["-I " ++ d | d <- getincludes flagl
                                   , not $ isabsinc d]
    (Stdout stdout, Stderr emsg, Exit ex) <-
          cmd ocamldep "-one-line -I" outdir incs ppflags src
    ppppe ex src emsg
    need $ deplist $ parseMakefile stdout
    let fixedflags = fixincludes flagl
    (Stderr emsg, Exit ex) <-
      cmd comp "-c -I" outdir fixedflags "-o" out ppflags src
    ppppe ex src emsg
    ordoracle $ OcamlOrdOracle out
    return ()
  where (target, suffix, op) = case t of
          CMO -> ("//*.cmo", ".ml", (%>))
          CMI -> ("//*.cmi", ".mli", (%>))
        deplist ((_, reqs) : _) =
          [if takeDirectory1 n == outdir then n else inOutDir n | n <- reqs]
        ppppe ExitSuccess _ _ = return ()
        ppppe _ src emsg = error $ fixpp src emsg

depl :: MVar [String]
depl = unsafePerformIO $ newMVar []

main = shakeArgs shakeOptions { shakeFiles = outdir
                              , shakeVerbosity = Normal
                              , shakeChange = ChangeModtimeAndDigest } $ do
  want ["build/llpp"]

  gitDescribeOracle <- addOracle $ \(GitDescribeOracle ()) -> do
    Stdout out <- cmd "git describe --tags --dirty"
    return (out :: String)

  ocamlOracle <- addOracle $ \(OcamlCmdLineOracle s) -> do
    return $ ocamlKey s

  ocamlOrdOracle <- addOracle $ \(OcamlOrdOracle s) -> do
    liftIO $ modifyMVar_ depl $ \l -> return $ s:l
    return ()

  cOracle <- addOracle $ \(CCmdLineOracle s) -> return $ cKey s

  inOutDir "help.ml" %> \out -> do
    version <- gitDescribeOracle $ GitDescribeOracle ()
    need ["mkhelp.sh", "KEYS"]
    Stdout f <- cmd "/bin/sh mkhelp.sh KEYS" version
    writeFileChanged out f

  inOutDir "link.o" %> \out -> do
    let key = dropDirectory1 out
    flags <- cOracle $ CCmdLineOracle key
    let src = key -<.> ".c"
    let dep = out -<.> ".d"
    unit $ cmd ocamlc "-ccopt"
      [flags ++ " -MMD -MF " ++ dep ++ " -o " ++ out] "-c" src
    needMakefileDependencies dep

  inOutDir "llpp" %> \out -> do
    need $ map inOutDir ["link.o", "main.cmo", "wsi.cmo", "help.ml"]
    cmos1 <- liftIO $ readMVar depl
    let cmos = [o | o <- reverse cmos1, takeExtension o /= ".cmi"]
    unit $ cmd ocamlc "-custom -I +lablGL -o " out
      "unix.cma str.cma lablgl.cma" cmos (inOutDir "link.o") "-cclib" [cclib]

  cm' outdir CMI ocamlOracle ocamlOrdOracle
  cm' outdir CMO ocamlOracle ocamlOrdOracle