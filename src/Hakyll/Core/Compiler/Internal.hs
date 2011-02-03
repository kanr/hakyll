-- | Internally used compiler module
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Hakyll.Core.Compiler.Internal
    ( Dependencies
    , CompilerEnvironment (..)
    , CompilerM (..)
    , Compiler (..)
    , runCompilerJob
    , runCompilerDependencies
    , fromJob
    , fromDependencies
    , fromDependency
    ) where

import Prelude hiding ((.), id)
import Control.Applicative (Applicative, pure, (<*>), (<$>))
import Control.Monad.Reader (ReaderT, Reader, ask, runReaderT, runReader)
import Control.Monad ((<=<), liftM2)
import Data.Set (Set)
import qualified Data.Set as S
import Control.Category (Category, (.), id)
import Control.Arrow (Arrow, arr, first)

import Hakyll.Core.Identifier
import Hakyll.Core.ResourceProvider
import Hakyll.Core.Store
import Hakyll.Core.Routes

-- | A set of dependencies
--
type Dependencies = Set Identifier

-- | Environment in which a compiler runs
--
data CompilerEnvironment = CompilerEnvironment
    { -- | Target identifier
      compilerIdentifier       :: Identifier
    , -- | Resource provider
      compilerResourceProvider :: ResourceProvider
    , -- | Site routes
      compilerRoutes           :: Routes
    , -- | Compiler store
      compilerStore            :: Store
    , -- | Flag indicating if the underlying resource was modified
      compilerResourceModified :: Bool
    }

-- | The compiler monad
--
newtype CompilerM a = CompilerM
    { unCompilerM :: ReaderT CompilerEnvironment IO a
    } deriving (Monad, Functor, Applicative)

-- | The compiler arrow
--
data Compiler a b = Compiler
    { compilerDependencies :: Reader ResourceProvider Dependencies
    , compilerJob          :: a -> CompilerM b
    }

instance Functor (Compiler a) where
    fmap f (Compiler d j) = Compiler d $ fmap f . j

instance Applicative (Compiler a) where
    pure = Compiler (return S.empty) . const . return
    (Compiler d1 f) <*> (Compiler d2 j) =
        Compiler (liftM2 S.union d1 d2) $ \x -> f x <*> j x

instance Category Compiler where
    id = Compiler (return S.empty) return
    (Compiler d1 j1) . (Compiler d2 j2) =
        Compiler (liftM2 S.union d1 d2) (j1 <=< j2)

instance Arrow Compiler where
    arr f = Compiler (return S.empty) (return . f)
    first (Compiler d j) = Compiler d $ \(x, y) -> do
        x' <- j x
        return (x', y)

-- | Run a compiler, yielding the resulting target and it's dependencies
--
runCompilerJob :: Compiler () a     -- ^ Compiler to run
               -> Identifier        -- ^ Target identifier
               -> ResourceProvider  -- ^ Resource provider
               -> Routes            -- ^ Route
               -> Store             -- ^ Store
               -> Bool              -- ^ Was the resource modified?
               -> IO a
runCompilerJob compiler identifier provider route store modified =
    runReaderT (unCompilerM $ compilerJob compiler ()) env
  where
    env = CompilerEnvironment
            { compilerIdentifier       = identifier
            , compilerResourceProvider = provider
            , compilerRoutes           = route
            , compilerStore            = store
            , compilerResourceModified = modified
            }

runCompilerDependencies :: Compiler () a
                        -> ResourceProvider
                        -> Dependencies
runCompilerDependencies compiler = runReader (compilerDependencies compiler)

fromJob :: (a -> CompilerM b)
        -> Compiler a b
fromJob = Compiler (return S.empty)

fromDependencies :: (ResourceProvider -> [Identifier])
                 -> Compiler b b
fromDependencies deps = Compiler (S.fromList . deps <$> ask) return

-- | Wait until another compiler has finished before running this compiler
--
fromDependency :: Identifier -> Compiler a a
fromDependency = fromDependencies . const . return
