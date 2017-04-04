{-# LANGUAGE UndecidableInstances #-}
-- Required to make passthrough instances for MonadContext for things like ReaderT work as they do not satisfy the functional dependency | m -> c

-- |Module with a `ReaderT` style monad specialized to holding a record.
module Control.Monad.Composite.Context
  ( ContextT(ContextT, runContextT), withContext, mapContextT
  , MonadContext(askContext, localContext), asksContext, askField
  ) where

import BasicPrelude hiding (empty)
import Composite.Record (Record)
import Control.Applicative (Alternative(empty))
import Control.Lens (Getter, view)
import Control.Monad.Base (MonadBase(liftBase))
import Control.Monad.Cont.Class (MonadCont(callCC))
import Control.Monad.Error.Class (MonadError(throwError, catchError))
import Control.Monad.Fail (MonadFail)
import qualified Control.Monad.Fail as MonadFail
import Control.Monad.Fix (MonadFix(mfix))
import Control.Monad.Reader.Class (MonadReader(local, ask, reader))
import Control.Monad.RWS.Class (MonadRWS)
import Control.Monad.State.Class (MonadState(get, put, state))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.Monad.Trans.Control (MonadTransControl(type StT, liftWith, restoreT), MonadBaseControl(type StM, liftBaseWith, restoreM))
import Control.Monad.Writer.Class (MonadWriter(writer, tell, listen, pass))

-- |Class of monad (stacks) which have context reading functionality baked in. Similar to 'Control.Monad.Reader.MonadReader' but can coexist with a
-- another monad that provides 'Control.Monad.Reader.MonadReader' and requires the context to be a record.
class Monad m => MonadContext (c :: [*]) m | m -> c where
  -- |Fetch the context record from the environment.
  askContext :: m (Record c)

  -- |Run some action which has the same type of context with the context modified.
  localContext :: (Record c -> Record c) -> m a -> m a

-- |Project some value out of the context using a function.
asksContext :: MonadContext c m => (Record c -> a) -> m a
asksContext f = f <$> askContext

-- |Project some value out of the context using a lens (typically a field lens).
askField :: MonadContext c m => Getter (Record c) a -> m a
askField l = asksContext $ view l

-- |Monad transformer which adds an implicit environment which is a record. Isomorphic to @ReaderT (Record c) m@.
newtype ContextT (c :: [*]) (m :: (* -> *)) a = ContextT { runContextT :: Record c -> m a }

-- |Permute the current context with a function and then run some action with that modified context.
withContext :: (Record c' -> Record c) -> ContextT c m a -> ContextT c' m a
withContext f action = ContextT $ \ c' -> runContextT action (f c')

-- |Transform the monad underlying a 'ContextT' using a natural transform.
mapContextT :: (m a -> n b) -> ContextT c m a -> ContextT c n b
mapContextT f m = ContextT $ f . runContextT m

instance Monad m => MonadContext c (ContextT c m) where
  askContext = ContextT pure
  localContext f action = ContextT $ runContextT action . f

instance Functor m => Functor (ContextT c m) where
  fmap f clt = ContextT $ fmap f . runContextT clt

instance Applicative m => Applicative (ContextT c m) where
  pure = ContextT . const . pure
  cltab <*> clta = ContextT $ \ r -> runContextT cltab r <*> runContextT clta r

instance Alternative m => Alternative (ContextT c m) where
  empty = ContextT . const $ empty
  m <|> n = ContextT $ \ r -> runContextT m r <|> runContextT n r

instance Monad m => Monad (ContextT c m) where
  clt >>= k = ContextT $ \ ctx -> do
    a <- runContextT clt ctx
    runContextT (k a) ctx

  fail = ContextT . const . fail

instance MonadIO m => MonadIO (ContextT c m) where
  liftIO = lift . liftIO

instance MonadTrans (ContextT c) where
  lift = ContextT . const

instance MonadTransControl (ContextT c) where
  type StT (ContextT c) a = a
  liftWith f = ContextT $ \ r -> f $ \ t -> runContextT t r
  restoreT = ContextT . const

instance MonadBase b m => MonadBase b (ContextT c m) where
  liftBase = ContextT . const . liftBase

instance MonadBaseControl b m => MonadBaseControl b (ContextT c m) where
  type StM (ContextT c m) a = StM m a
  restoreM = ContextT . const . restoreM
  liftBaseWith f =
    ContextT $ \ c ->
      liftBaseWith $ \ runInBase ->
        f (runInBase . ($ c) . runContextT)

instance MonadReader r m => MonadReader r (ContextT c m) where
  ask    = lift ask
  local  = mapContextT . local
  reader = lift . reader

instance MonadWriter w m => MonadWriter w (ContextT c m) where
  writer = lift . writer
  tell   = lift . tell
  listen = mapContextT listen
  pass   = mapContextT pass

instance MonadState s m => MonadState s (ContextT c m) where
  get   = lift get
  put   = lift . put
  state = lift . state

instance MonadRWS r w s m => MonadRWS r w s (ContextT c m)

instance MonadFix m => MonadFix (ContextT c m) where
  mfix f = ContextT $ \ r -> mfix $ \ a -> runContextT (f a) r

instance MonadFail m => MonadFail (ContextT c m) where
  fail = lift . MonadFail.fail

instance MonadError e m => MonadError e (ContextT c m) where
  throwError = lift . throwError
  catchError m h = ContextT $ \ r -> catchError (runContextT m r) (\ e -> runContextT (h e) r)

instance MonadPlus m => MonadPlus (ContextT c m) where
  mzero = lift mzero
  m `mplus` n = ContextT $ \ r -> runContextT m r `mplus` runContextT n r

instance MonadCont m => MonadCont (ContextT c m) where
  callCC f = ContextT $ \ r -> callCC $ \ c -> runContextT (f (ContextT . const . c)) r