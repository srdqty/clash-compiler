{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
module RotateCNested where

import Clash.Prelude.Testbench
import Clash.Prelude
import GHC.Generics
import Clash.Annotations.BitRepresentation
import Data.Maybe

-- Test data structures:
data Color
  = Red
  | Green
  | Blue
    deriving (Eq, Show{-, Generic, ShowX-})

data MaybeColor
  = NothingC
  | JustC Color
    deriving (Eq, Show{-, Generic, ShowX-})

-- Test functions:
rotateColor
  :: Color
  -> Color
rotateColor c =
  case c of
    Red   -> Green
    Green -> Blue
    Blue  -> Red

colorToInt
  :: Color
  -> Int
colorToInt Red   = 33
colorToInt Green = 34
colorToInt Blue  = 35

topEntity
  :: SystemClockReset
  => Signal System (Maybe MaybeColor)
  -> Signal System Int
topEntity = fmap (colorToInt . f)
  where
    f cM =
      case cM of
        Just (JustC c) -> rotateColor c
        Just NothingC  -> Blue
        Nothing        -> Red
{-# NOINLINE topEntity #-}

-- Testbench:
testBench :: Signal System Bool
testBench = done'
  where
    testInput = stimuliGenerator $ Nothing
                               :> Just (NothingC)
                               :> Just (JustC Red)
                               :> Just (JustC Green)
                               :> Just (JustC Blue)
                               :> Nil

    expectedOutput = outputVerifier $ 33 -- Red
                                   :> 35 -- Blue
                                   :> 34 -- Green
                                   :> 35 -- Blue
                                   :> 33 -- Red
                                   :> Nil

    done  = expectedOutput (topEntity testInput)
    done' = withClockReset (tbSystemClockGen (not <$> done')) systemResetGen done