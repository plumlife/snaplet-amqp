{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}

module Snap.Snaplet.AMQP
  ( AmqpState   (..)
  , HasAmqpPool (..)
  , PersistentAMQP (..)
  , createPersistentAMQP
  , initAMQP
  , runAmqp
  ) where

import           Control.Applicative
import           Control.Concurrent         (threadDelay)
import           Control.Exception          (throw, try)
import           Control.Monad              (liftM, unless, void)
import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Control.Monad.State        (gets)
import           Control.Monad.Trans.Reader (ReaderT, ask)
import           Data.Configurator          (require)
import           Data.IORef
import           Data.Pool
import           Data.Time
import           Network.AMQP
import           Paths_snaplet_amqp
import           Snap.Snaplet
import           System.Locale
import qualified System.Log.Logger          as Logger

--------------------------------------------------------------------------------
type AmqpPool     = Pool Channel
newtype AmqpState = AmqpState { amqpPoolAct :: IO AmqpPool }

--------------------------------------------------------------------------------
class MonadIO m => HasAmqpPool m where
  getAmqpPool :: m AmqpPool

instance HasAmqpPool (Handler b AmqpState) where
  getAmqpPool = liftIO =<< gets amqpPoolAct

instance MonadIO m => HasAmqpPool (ReaderT AmqpPool m) where
  getAmqpPool = ask

--------------------------------------------------------------------------------

-- | Represents an AMQP connection which retries automatically upon
-- disconnection from the server. The @paCloseConn@ operation should be used by
-- the caller to destroy the connection (which also destroys the pool), and the
-- @paGetConn@ and @paGetPool@ actions to get ahold of a valid connection/pool
-- for AMQP operations. NB: The result of these accessors may go stale due to a
-- dropped connection (i.e., it hides an IORef), so it is generally best to call
-- the accessor whenever the value is needed instead of holding onto the
-- result. Anecdotally, use of a stale connection/pool results in messages being
-- dropped, not a systemic crash. If we end up running into problems with races,
-- we can move to a TMVar approach for the connection/pool accessors instead,
-- with a little more operational burden places on the caller.
data PersistentAMQP = PersistentAMQP
                      { paCloseConn :: IO ()
                      , paGetConn   :: IO Connection
                      , paGetPool   :: IO AmqpPool
                      }

createPersistentAMQP :: (String -> IO ())
                        -- ^ Logger
                     -> ConnectionOpts
                        -- ^ How to connect to the AMQP server
                     -> Maybe (Connection -> IO AmqpPool)
                        -- ^ How to (re-)create an AMQP channel pool (Nothing =>
                        -- use a reasonable default pool creation routine); note
                        -- that this pool is managed entirely by the resulting
                        -- @PersistentAMQP@ actions.
                     -> Maybe (IO ())
                        -- ^ Optional cb on connection refresh
                     -> IO PersistentAMQP
createPersistentAMQP notice connOpts mmkUserPool monRefreshConn = do
  rhalt <- newIORef False -- Not in a halt state initially

  let
    mkPool mrc mrp = do
      (c, rc) <- connectAMQP
      rp      <- updRef mrp =<< mkUserPool c
      addConnectionClosedHandler c True $ do
        notice "Connection closed, destroying invalidated AMQP channel pool"
        destroyAllResources =<< readIORef rp
        halt <- readIORef rhalt
        unless halt $ do
          notice "Re-establishing connection"
          void $ mkPool (Just rc) (Just rp)
      return (rc, rp)
      where
        firstAttempt = maybe True (const False) mrp
        connectAMQP  = try (openConnection'' connOpts) >>= \case
          Left (e :: AMQPException)
            | not firstAttempt -> do
                notice "Failed to re-establish, trying again in 1s"
                threadDelay 1000000
                connectAMQP
            | otherwise ->
                throw e
          Right c -> do
            notice "Connection established"
            rc <- updRef mrc c
            unless firstAttempt $! maybe (return ()) id monRefreshConn
            return (c, rc)

    mkUserPool = case mmkUserPool of
      Just f  -> f
      Nothing -> \c ->
        createPool (openChannel c) closeChannel 1 30 10
          <* do notice "Created AMQP channel pool"

    closeIt rc = do
      atomicWriteIORef rhalt True
      closeConnection =<< readIORef rc

    updRef Nothing v  = newIORef v
    updRef (Just r) v = atomicWriteIORef r v >> return r

  (rc, rp) <- mkPool Nothing Nothing
  return $ PersistentAMQP (closeIt rc) (readIORef rc) (readIORef rp)

--------------------------------------------------------------------------------

-- | Initialize the AMQP Snaplet.
initAMQP :: SnapletInit b AmqpState
initAMQP = makeSnaplet "amqp" description datadir $ do
  liftIO $ Logger.updateGlobalLogger "Console" (Logger.setLevel Logger.INFO)
  connOpts <- getConnOpts
  pa       <- liftIO $ createPersistentAMQP logger connOpts Nothing Nothing
  onUnload $ paCloseConn pa
  return $! AmqpState (paGetPool pa)
  where
    description = "Snaplet for AMQP library"
    datadir     = Just $ liftM (++"/resources/amqp") getDataDir
    logger msg  = do
      now <- formatTime defaultTimeLocale (iso8601DateFormat $ Just "%H:%M:%S")
             <$> getCurrentTime
      let pri = Logger.INFO
      Logger.logM "Console" pri
        (now ++ " [" ++ show pri ++ "] " ++ "AMQP: " ++ msg)
    getConnOpts = do
      conf <- getSnapletUserConfig
      liftIO $ do
        host  <- require conf "host"
        port  <- require conf "port"
        vhost <- require conf "vhost"
        login <- require conf "login"
        pass  <- require conf "password"
        return $
          defaultConnectionOpts
            { coServers        = [(host, fromInteger port)]
            , coVHost          = vhost
            , coAuth           = [plain login pass]
            , coHeartbeatDelay = Just 1
            }

--------------------------------------------------------------------------------

-- | Runs an AMQP action in any monad with a HasAmqpPool instance.
runAmqp :: HasAmqpPool m => (Channel -> IO a) -> m a
runAmqp action = getAmqpPool >>= \p -> liftIO $! withResource p $! (action $!)
