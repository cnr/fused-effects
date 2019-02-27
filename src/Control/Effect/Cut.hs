{-# LANGUAGE DeriveTraversable, ExistentialQuantification, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving, LambdaCase, MultiParamTypeClasses, RankNTypes, StandaloneDeriving, TypeOperators, UndecidableInstances #-}
module Control.Effect.Cut
( Cut(..)
, cutfail
, call
, cut
, runCut
, CutC(..)
, ListC(..)
, runListAll
, runListAlt
, BTree(..)
, BTreeC(..)
) where

import Control.Applicative (Alternative(..))
import Control.Effect.Carrier
import Control.Effect.NonDet
import Control.Effect.State
import Control.Effect.Sum
import Control.Monad (join)

-- | 'Cut' effects are used with 'NonDet' to provide control over backtracking.
data Cut m k
  = Cutfail
  | forall a . Call (m a) (a -> k)

deriving instance Functor (Cut m)

instance HFunctor Cut where
  hmap _ Cutfail    = Cutfail
  hmap f (Call m k) = Call (f m) k
  {-# INLINE hmap #-}

instance Effect Cut where
  handle _     _       Cutfail    = Cutfail
  handle state handler (Call m k) = Call (handler (m <$ state)) (handler . fmap k)
  {-# INLINE handle #-}

-- | Fail the current branch, and prevent backtracking within the nearest enclosing 'call' (if any).
--
--   Contrast with 'empty', which fails the current branch but allows backtracking.
--
--   prop> run (runNonDet (runCut (cutfail <|> pure a))) == []
--   prop> run (runNonDet (runCut (pure a <|> cutfail))) == [a]
cutfail :: (Carrier sig m, Member Cut sig) => m a
cutfail = send Cutfail
{-# INLINE cutfail #-}

-- | Delimit the effect of 'cutfail's, allowing backtracking to resume.
--
--   prop> run (runNonDet (runCut (call (cutfail <|> pure a) <|> pure b))) == [b]
call :: (Carrier sig m, Member Cut sig) => m a -> m a
call m = send (Call m pure)
{-# INLINE call #-}

-- | Commit to the current branch, preventing backtracking within the nearest enclosing 'call' (if any) on failure.
--
--   prop> run (runNonDet (runCut (pure a <|> cut *> pure b))) == [a, b]
--   prop> run (runNonDet (runCut (cut *> pure a <|> pure b))) == [a]
--   prop> run (runNonDet (runCut (cut *> empty <|> pure a))) == []
cut :: (Alternative m, Carrier sig m, Member Cut sig) => m ()
cut = pure () <|> cutfail
{-# INLINE cut #-}


-- | Run a 'Cut' effect within an underlying 'Alternative' instance (typically another 'Carrier' for a 'NonDet' effect).
--
--   prop> run (runNonDetOnce (runCut (pure a))) == Just a
runCut :: (Alternative m, Carrier sig m) => CutC m a -> m a
runCut = evalState True . runListAlt . runCutC

newtype CutC m a = CutC { runCutC :: ListC (StateC Bool m) a }
  deriving (Applicative, Functor, Monad)

instance (Carrier sig m, Effect sig) => Alternative (CutC m) where
  empty = send Empty
  l <|> r = send (Choose (\ c -> if c then l else r))

instance (Carrier sig m, Effect sig) => Carrier (Cut :+: NonDet :+: sig) (CutC m) where
  eff = CutC . handleSum (handleSum
    (eff . R . R . handleCoercible)
    (\case
      Empty    -> ListC $ \ _    nil -> nil
      Choose k -> ListC $ \ cons nil -> do
        let handle a as = do
              shouldBacktrack <- get
              if shouldBacktrack then do
                maybe id cons a $ runListC (runCutC (k False)) cons as
              else
                maybe nil (flip cons nil) a
        runListC (runCutC (k True)) (handle . Just) (handle Nothing nil)))
    (\case
      Cutfail  -> ListC $ \ _    nil -> put False *> nil
      Call m k -> ListC $ \ cons nil -> do
        shouldBacktrack <- get
        runListC (runCutC m) (\ a as -> put shouldBacktrack *> runListC (runCutC (k a)) cons as) (put (shouldBacktrack :: Bool) *> nil))
  {-# INLINE eff #-}


newtype ListC m a = ListC { runListC :: forall b . (a -> m b -> m b) -> m b -> m b }
  deriving (Functor)

runListAll :: (Alternative f, Applicative m) => ListC m a -> m (f a)
runListAll (ListC m) = m (fmap . (<|>) . pure) (pure empty)

runListAlt :: Alternative m => ListC m a -> m a
runListAlt (ListC m) = m ((<|>) . pure) empty

instance Applicative (ListC m) where
  pure a = ListC (\ cons -> cons a)
  ListC f <*> ListC a = ListC $ \ cons ->
    f (\ f' -> a (cons . f'))

instance Alternative (ListC m) where
  empty = ListC (\ _ nil -> nil)
  ListC l <|> ListC r = ListC $ \ cons -> l cons . r cons

instance Monad (ListC m) where
  ListC a >>= f = ListC $ \ cons ->
    a (\ a' -> runListC (f a') cons)

instance (Carrier sig m, Effect sig) => Carrier (NonDet :+: sig) (ListC m) where
  eff (L Empty) = empty
  eff (L (Choose k)) = k True <|> k False
  eff (R other) = ListC $ \ cons nil -> eff (handle (Leaf ()) (fmap join . traverse runListAll) other) >>= foldr cons nil


data BTree a = Nil | Leaf a | Branch (BTree a) (BTree a)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

instance Applicative BTree where
  pure = Leaf
  Nil          <*> _ = Nil
  Leaf f       <*> a = fmap f a
  Branch f1 f2 <*> a = Branch (f1 <*> a) (f2 <*> a)

instance Alternative BTree where
  empty = Nil
  (<|>) = Branch

instance Monad BTree where
  Nil          >>= _ = Nil
  Leaf a       >>= f = f a
  Branch a1 a2 >>= f = Branch (a1 >>= f) (a2 >>= f)


newtype BTreeC m a = BTreeC { runBTreeC :: forall b . (m b -> m b -> m b) -> (a -> m b) -> m b -> m b }
  deriving (Functor)

instance Applicative (BTreeC m) where
  pure a = BTreeC $ \ _ pur _ -> pur a
  BTreeC f <*> BTreeC a = BTreeC $ \ alt pur nil ->
    f alt (\ f' -> a alt (pur . f') nil) nil


-- $setup
-- >>> :seti -XFlexibleContexts
-- >>> import Test.QuickCheck
-- >>> import Control.Effect.Void
