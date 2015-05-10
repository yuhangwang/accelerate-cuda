{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE TypeOperators              #-}
-- |
-- Module      : Data.Array.Accelerate.CUDA.AST
-- Copyright   : [2008..2014] Manuel M T Chakravarty, Gabriele Keller
--               [2009..2014] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.CUDA.AST (

  module Data.Array.Accelerate.AST,

  AccKernel(..), Free, Gamma(..), Idx_(..),
  ExecAcc, ExecAfun, ExecOpenAfun, ExecOpenAcc(..),
  ExecExp, ExecFun, ExecOpenExp, ExecOpenFun,
  ExecSeq(..), ExecOpenSeq(..), ExecP(..), ExecC(..),
  freevar, makeEnvMap,

) where

-- friends
import Data.Array.Accelerate.AST
import Data.Array.Accelerate.Lifetime
import Data.Array.Accelerate.Pretty
import Data.Array.Accelerate.Array.Lifted               ( Regular )
import Data.Array.Accelerate.Array.Sugar                ( Array, Shape, Elt, Arrays, Vector, EltRepr, Atuple, TupleRepr, IsAtuple, Scalar, (:.)
                                                        , DIM3, DIM5, DIM7, DIM9 )

import Data.Array.Accelerate.Array.Representation       ( SliceIndex(..) )
import Data.Array.Accelerate.Trafo                      ( Extend, DelayedOpenAcc )
import qualified Data.Array.Accelerate.FullList         as FL
import qualified Foreign.CUDA.Driver                    as CUDA
import qualified Foreign.CUDA.Analysis                  as CUDA

-- system
import Text.PrettyPrint
import Data.Hashable
import Data.Monoid                                      hiding ( (<>) )
import qualified Data.HashSet                           as Set
import qualified Data.HashMap.Strict                    as Map
import Prelude


-- A non-empty list of binary objects will be used to execute a kernel. We keep
-- auxiliary information together with the compiled module, such as entry point
-- and execution information.
--
data AccKernel a where
  AccKernel :: !String                                -- __global__ entry function name
            -> {-# UNPACK #-} !CUDA.Fun               -- __global__ function object
            -> {-# UNPACK #-} !(Lifetime CUDA.Module) -- binary module
            -> {-# UNPACK #-} !CUDA.Occupancy         -- occupancy analysis
            -> {-# UNPACK #-} !Int                    -- thread block size
            -> {-# UNPACK #-} !Int                    -- shared memory per block (bytes)
            -> !(Int -> Int)                          -- number of blocks for input problem size
            -> AccKernel a


-- Kernel execution is asynchronous, barriers allow (cross-stream)
-- synchronisation to determine when the operation has completed
--
-- data AccBarrier = AB !Stream !Event


-- The set of free array variables for array computations that were embedded
-- within scalar expressions. These arrays are are required to execute the
-- kernel, by binding to texture references to similar.
--
type Free aenv = Set.HashSet (Idx_ aenv)

freevar :: (Shape sh, Elt e) => Idx aenv (Array sh e) -> Free aenv
freevar = Set.singleton . Idx_


-- A mapping between environment indexes and some token identifying that array
-- in the generated code. This simply compresses the sequence of array indices
-- into a continuous range, rather than directly using the integer equivalent of
-- the de Bruijn index.
--
-- This results in generated code that is (slightly) less sensitive to the
-- placement of let bindings, ultimately leading to a higher hit rate in the
-- compilation cache.
--
newtype Gamma aenv = Gamma ( Map.HashMap (Idx_ aenv) Int )
  deriving ( Monoid )

makeEnvMap :: Free aenv -> Gamma aenv
makeEnvMap indices
  = Gamma
  . Map.fromList
  . flip zip [0..]
--  . sortBy (compare `on` idxType)
  $ Set.toList indices
--  where
--    idxType :: Idx_ aenv -> TypeRep
--    idxType (Idx_ (_ :: Idx aenv (Array sh e))) = typeOf (undefined :: e)


-- Opaque array environment indices
--
data Idx_ aenv where
  Idx_ :: (Shape sh, Elt e) => Idx aenv (Array sh e) -> Idx_ aenv

instance Eq (Idx_ aenv) where
  Idx_ ix1 == Idx_ ix2 = idxToInt ix1 == idxToInt ix2

instance Hashable (Idx_ aenv) where
  hashWithSalt salt (Idx_ ix)
    = salt `hashWithSalt` idxToInt ix


-- Interleave compilation & execution state annotations into an open array
-- computation AST
--
data ExecOpenAcc aenv a where
  ExecAcc   :: {-# UNPACK #-} !(FL.FullList () (AccKernel a))   -- executable binary objects
            -> !(Gamma aenv)                                    -- free array variables the kernel needs access to
            -> !(PreOpenAcc ExecOpenAcc aenv a)                 -- the actual computation
            -> ExecOpenAcc aenv a                               -- the recursive knot

  EmbedAcc  :: (Shape sh, Elt e)
            => !(PreExp ExecOpenAcc aenv sh)                    -- shape of the result array, used by execution
            -> ExecOpenAcc aenv (Array sh e)

  ExecSeq :: Arrays arrs
           => PreOpenSeq DelayedOpenAcc aenv () arrs -- For shape analysis
           -> ExecOpenSeq aenv () arrs
           -> ExecOpenAcc aenv arrs


-- An annotated AST suitable for execution in the CUDA environment
--
type ExecAcc  a         = ExecOpenAcc () a
type ExecAfun a         = PreAfun ExecOpenAcc a
type ExecOpenAfun aenv a = PreOpenAfun ExecOpenAcc aenv a

type ExecOpenExp        = PreOpenExp ExecOpenAcc
type ExecOpenFun        = PreOpenFun ExecOpenAcc

type ExecExp            = ExecOpenExp ()
type ExecFun            = ExecOpenFun ()


-- Display the annotated AST
-- -------------------------

instance Show (ExecOpenAcc aenv a) where
  show = render . prettyExecAcc 0 noParens

instance Show (ExecAfun a) where
  show = render . prettyExecAfun 0

prettyExecAfun :: Int -> ExecAfun a -> Doc
prettyExecAfun alvl pfun = prettyPreAfun prettyExecAcc alvl pfun

prettyExecAcc :: PrettyAcc ExecOpenAcc
prettyExecAcc alvl wrap exec =
  case exec of
    EmbedAcc sh ->
      wrap $ hang (text "Embedded") 2
           $ sep [ prettyPreExp prettyExecAcc 0 alvl parens sh ]

    ExecAcc _ (Gamma fv) pacc ->
      let base      = prettyPreAcc prettyExecAcc alvl wrap pacc
          ann       = braces (freevars (Map.keys fv))
          freevars  = (text "fv=" <>) . brackets . hcat . punctuate comma
                                      . map (\(Idx_ ix) -> char 'a' <> int (idxToInt ix))
      in
      case pacc of
        Avar{}          -> base
        Alet{}          -> base
        Apply{}         -> base
        Acond{}         -> base
        Atuple{}        -> base
        Aprj{}          -> base
        _               -> ann <+> base

    ExecSeq{} -> text "<SequenceComputation>"

data ExecSeq a where
  ExecS :: Extend ExecOpenAcc () aenv
        -> PreOpenSeq DelayedOpenAcc aenv () a -- For shape analysis
        -> ExecOpenSeq aenv () a -> ExecSeq a

data ExecOpenSeq aenv lenv arrs where
  ExecP :: Arrays a => ExecP aenv lenv a -> ExecOpenSeq aenv (lenv, a) arrs -> ExecOpenSeq aenv lenv  arrs
  ExecC :: Arrays a => ExecC aenv lenv a -> ExecOpenSeq aenv lenv a
  ExecR :: Arrays a
        => Maybe (ExecOpenAfun aenv (Regular a -> Scalar Int -> a))
        -> Idx lenv a -> ExecOpenSeq aenv lenv [a]

data ExecP aenv lenv a where

  ExecToSeq    :: (Elt slix, Shape sl, Shape sh, Elt e)
               => Maybe (ExecOpenAfun aenv (Array (sl :. Int) e -> Regular (Array sl e)))
               -> SliceIndex (EltRepr slix)
                             (EltRepr sl)
                             co
                             (EltRepr sh)
               -> !(proxy slix)
               -> Either
                    ( Array sh e
                      -- Permutation kernels:
                    , AccKernel (Array DIM3 e)
                    , AccKernel (Array DIM5 e)
                    , AccKernel (Array DIM7 e)
                    , AccKernel (Array DIM9 e)
                    ) -- Use lazy
                    ( ExecExp aenv sh
                    , AccKernel (Array (sl :. Int) e) -- Fused kernel
                    , Gamma aenv
                    )
               -> ExecP aenv lenv (Array sl e)

  ExecStreamIn :: Arrays a
               => [a]
               -> ExecP aenv lenv a

  ExecMap :: (Arrays a, Arrays b)
          => ExecOpenAfun aenv (a -> b)
          -> Maybe (ExecOpenAfun aenv (Regular a -> Regular b))
          -> Idx lenv a
          -> ExecP aenv lenv b

  ExecZipWith :: (Arrays a, Arrays b, Arrays c)
              => ExecOpenAfun aenv (a -> b -> c)
              -> Maybe (ExecOpenAfun aenv (Regular a -> Regular b -> Regular c))
              -> Idx lenv a
              -> Idx lenv b
              -> ExecP aenv lenv c

  ExecScanSeq :: Elt a
              => ExecExp aenv a
              -> ExecOpenAfun aenv (Scalar a -> Scalar a -> Scalar a)  -- zipper
              -> ExecOpenAfun aenv (Scalar a -> Vector a -> (Vector a, Scalar a)) -- scanner
              -> Idx lenv (Scalar a)
              -> ExecP aenv lenv (Scalar a)

data ExecC aenv lenv a where
  ExecFoldSeq :: Elt a
              => Maybe (ExecOpenAfun aenv (Vector a -> Vector a -> Vector a))
              -> ExecOpenAfun aenv (Vector a -> Scalar a)
              -> ExecExp aenv a
              -> ExecOpenAfun aenv (Scalar a -> Scalar a -> Scalar a)  -- zipper
              -> Idx lenv (Scalar a)
              -> ExecC aenv lenv (Scalar a)

  ExecFoldSeqFlatten :: (Arrays a, Shape sh, Elt e)
                     => Maybe (ExecOpenAfun aenv (a -> Regular (Array sh e) -> a))
                     -> ExecOpenAfun aenv (a -> Vector sh -> Vector e -> a)
                     -> ExecOpenAcc aenv a
                     -> Idx lenv (Array sh e)
                     -> ExecC aenv lenv a

  ExecStuple :: (Arrays a, IsAtuple a)
             => Atuple (ExecC aenv senv) (TupleRepr a)
             -> ExecC aenv senv a

