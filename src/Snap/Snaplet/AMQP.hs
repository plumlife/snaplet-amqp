{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Snap.Snaplet.AMQP
  ( AmqpState   (..)
  , HasAmqpPool (..)
  , initAMQP
  , mkAmqpPool
  , runAmqp
  ) where

import           Control.Concurrent          (threadDelay)
import           Control.Exception           (try, throw)
import           Control.Monad               (liftM, unless, void)
import           Control.Monad.State         (gets)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Control.Monad.Trans.Reader  (ReaderT, ask)
import           Data.Configurator           (require)
import           Data.IORef
import           Data.Pool
import           Network.AMQP
import           Paths_snaplet_amqp
import           Snap.Snaplet

--------------------------------------------------------------------------------
type AmqpPool     = Pool Channel
newtype AmqpState = AmqpState { amqpPoolRef :: IORef AmqpPool }

--------------------------------------------------------------------------------
class MonadIO m => HasAmqpPool m where
  getAmqpPool :: m AmqpPool

instance HasAmqpPool (Handler b AmqpState) where
  getAmqpPool = liftIO . readIORef =<< gets amqpPoolRef

instance MonadIO m => HasAmqpPool (ReaderT AmqpPool m) where
  getAmqpPool = ask

--------------------------------------------------------------------------------

-- | Initialize the AMQP Snaplet.
initAMQP :: SnapletInit b AmqpState
initAMQP = makeSnaplet "amqp" description datadir $ do
  connOpts <- getConnOpts
  rhalt    <- liftIO $ newIORef False   -- Not in halt state
  rmc      <- liftIO $ newIORef Nothing -- No connection yet
  rp       <- mkAmqpPool connOpts rhalt rmc Nothing

  onUnload $ do
    atomicWriteIORef rhalt True
    maybe (return ()) closeConnection =<< readIORef rmc

  return $! AmqpState rp

  where
    description = "Snaplet for AMQP library"
    datadir     = Just $ liftM (++"/resources/amqp") getDataDir
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
      
-- | Establish an AMQP connection and channel pool using the given connection
-- options, attempting to re-establish the connection whenever it dies unless
-- the 'IORef Bool' parameter indicates a halting state. Passing Nothing for the
-- 4th parameter indicates that this is the toplevel invocation and that a
-- channel pool does not yet exist; the Just-wrapped invocation is used by the
-- function internally.
mkAmqpPool :: MonadIO m
           => ConnectionOpts           -- ^ How we should connect to AMQP
           -> IORef Bool               -- ^ Halting? (prevents reconnection)
           -> IORef (Maybe Connection) -- ^ Connection outparam
           -> Maybe (IORef AmqpPool)   -- ^ Active pool (lazily init, feed forward)
           -> m (IORef AmqpPool)
mkAmqpPool connOpts rhalt rmc mrp = liftIO $ do
  c  <- connectAMQP
  rp <- do
        p <- createPool (openChannel c) closeChannel 1 30 10
        case mrp of
          Nothing -> newIORef p
          Just rp -> atomicWriteIORef rp p >> return rp

  addConnectionClosedHandler c True $ do
    notice "connection closed, destroying invalidated AMQP channel pool"
    destroyAllResources =<< readIORef rp
    halt <- readIORef rhalt
    unless halt $ do
      notice "re-establishing connection"
      void $ mkAmqpPool connOpts rhalt rmc (Just rp)

  return rp

  where
    shouldRetry = maybe False (const True) mrp
    connectAMQP = do
      eec <- try (openConnection'' connOpts)
      case eec of
        Left (e :: AMQPException) -> do
          if shouldRetry
          then do
               notice "failed to re-establish, trying again in 1s"
               threadDelay 1000000
               connectAMQP
          else throw e
        Right c -> do
          atomicWriteIORef rmc (Just c)
          notice "connection established"
          return c

notice :: String -> IO ()
notice = putStrLn . ("snaplet-amqp: " ++)

--------------------------------------------------------------------------------

-- | Runs an AMQP action in any monad with a HasAmqpPool instance.
runAmqp :: HasAmqpPool m => (Channel -> IO ()) -> m ()
runAmqp action = getAmqpPool >>= \p -> liftIO $! withResource p $! (action $!)
                 
