{-# LANGUAGE FlexibleContexts, RankNTypes, ScopedTypeVariables, TypeApplications #-}
module Writer
( tests
) where

import qualified Control.Carrier.Writer.Strict as StrictWriterC
import Control.Effect.Writer
import qualified Control.Monad.Trans.RWS.Lazy as LazyRWST
import qualified Control.Monad.Trans.RWS.Strict as StrictRWST
import qualified Control.Monad.Trans.Writer.Lazy as LazyWriterT
import qualified Control.Monad.Trans.Writer.Strict as StrictWriterT
import Data.Tuple (swap)
import Hedgehog
import Hedgehog.Function
import Hedgehog.Gen
import Hedgehog.Range
import Pure
import Test.Tasty
import Test.Tasty.Hedgehog

tests :: TestTree
tests = testGroup "Writer"
  [ testGroup "WriterC (Strict)" $ writerTests StrictWriterC.runWriter
  , testGroup "WriterT (Lazy)"   $ writerTests (fmap swap . LazyWriterT.runWriterT)
  , testGroup "WriterT (Strict)" $ writerTests (fmap swap . StrictWriterT.runWriterT)
  , testGroup "RWST (Lazy)"      $ writerTests (runRWST LazyRWST.runRWST)
  , testGroup "RWST (Strict)"    $ writerTests (runRWST StrictRWST.runRWST)
  ] where
  writerTests :: Has (Writer [A]) sig m => (forall a . m a -> PureC ([A], a)) -> [TestTree]
  writerTests run = Writer.writerTests run (genM (gen w)) w genA
  w = list (linear 0 10) genA
  runRWST f m = (\ (a, _, w) -> (w, a)) <$> f m () ()


gen :: forall w m a sig . (Has (Writer w) sig m, Arg w, Vary w) => Gen w -> (forall a . Gen a -> Gen (m a)) -> Gen a -> Gen (m a)
gen w m a = choice
  [ tell' <$> w <*> a
  , subtermM (m a) (\ m -> choice [(\ f -> apply f . fst <$> listen @w m) <$> fn a, pure (snd <$> listen @w m)])
  , fn w >>= subterm (m a) . censor . apply
  ] where
  tell' w a = a <$ tell w


writerTests :: (Has (Writer w) sig m, Arg w, Eq a, Eq w, Monoid w, Show a, Show w, Vary w) => (forall a . (m a -> PureC (w, a))) -> (forall a . Gen a -> Gen (Blind (m a))) -> Gen w -> Gen a -> [TestTree]
writerTests runWriter m w a =
  [ testProperty "tell append" . forall (w :. m a :. Nil) $
    \ w m -> tell_append (~=) runWriter w (getBlind m)
  , testProperty "listen eavesdrop" . forall (m a :. Nil) $
    \ m -> listen_eavesdrop (~=) runWriter (getBlind m)
  , testProperty "censor revision" . forall (fn w :. m a :. Nil) $
    \ f m -> censor_revision (~=) runWriter (apply f) (getBlind m)
  ]
