{-# LANGUAGE CPP #-}
module Main (main) where

import           Prelude ()
import           Prelude.Compat hiding (exp)
import           System.IO (hSetEncoding, stdout, stderr, utf8)
import           Test.Hspec

import qualified Test.CoreFn
import qualified Test.Eval
import qualified Test.Lib
-- TODO: it shouldn't be a CPP FLAG
#ifdef TEST_CORE_LIBS
import qualified Test.CoreLib
#endif

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8

  hspec Test.CoreFn.spec
  hspec Test.Eval.spec
  hspec Test.Lib.spec
#ifdef TEST_CORE_LIBS
  hspec Test.CoreLib.spec
#endif
