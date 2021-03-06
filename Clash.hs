{-# LANGUAGE CPP #-}

#include "MachDeps.h"
#define HDLSYN Other

import Clash.Driver
import Clash.Driver.Types
import Clash.GHC.Evaluator
import Clash.GHC.GenerateBindings
import Clash.GHC.NetlistTypes
import Clash.Backend
import Clash.Backend.SystemVerilog
import Clash.Backend.VHDL
import Clash.Backend.Verilog
import Clash.Netlist.BlackBox.Types
import Clash.Annotations.BitRepresentation.Internal (buildCustomReprs)

import Control.DeepSeq
import qualified Data.Time.Clock as Clock
import qualified Data.HashMap.Strict as HM

import GHC.Stack (HasCallStack)

genSystemVerilog
  :: String
  -> IO ()
genSystemVerilog = doHDL (initBackend WORD_SIZE_IN_BITS HDLSYN :: SystemVerilogState)

genVHDL
  :: String
  -> IO ()
genVHDL = doHDL (initBackend WORD_SIZE_IN_BITS HDLSYN :: VHDLState)

genVerilog
  :: String
  -> IO ()
genVerilog = doHDL (initBackend WORD_SIZE_IN_BITS HDLSYN :: VerilogState)

doHDL
  :: HasCallStack
  => Backend s
  => s
  -> String
  -> IO ()
doHDL b src = do
  startTime <- Clock.getCurrentTime
  pd      <- primDirs b
  (bindingsMap,tcm,tupTcm,topEntities,primMap,reprs) <- generateBindings pd ["."] (hdlKind b) src Nothing
  prepTime <- startTime `deepseq` bindingsMap `deepseq` tcm `deepseq` reprs `deepseq` Clock.getCurrentTime
  let prepStartDiff = Clock.diffUTCTime prepTime startTime
  putStrLn $ "Loading dependencies took " ++ show prepStartDiff

  -- Parse primitives:
  startTime' <- Clock.getCurrentTime
  primMap2   <- sequence $ HM.map compilePrimitive primMap
  prepTime'  <- startTime `deepseq` primMap2 `seq` Clock.getCurrentTime
  let prepStartDiff' = Clock.diffUTCTime prepTime' startTime'
  putStrLn $ "Parsing primitives took " ++ show prepStartDiff'

  generateHDL (buildCustomReprs reprs) bindingsMap (Just b) primMap2 tcm tupTcm (ghcTypeToHWType WORD_SIZE_IN_BITS True) reduceConstant topEntities
    (ClashOpts 20 20 15 0 DebugNone False True WORD_SIZE_IN_BITS Nothing HDLSYN True True ["."] Nothing) (startTime,prepTime)

main :: IO ()
main = genVHDL "./examples/FIR.hs"
