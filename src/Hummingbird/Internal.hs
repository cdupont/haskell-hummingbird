{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
module Hummingbird.Internal
  ( Hummingbird (..)
  , new
  , start
  , stop
  -- * Authenticator operations
  , restartAuthenticator
  -- * Config operations
  , getConfig
  , reloadConfig
  -- * Transport thread operations
  , startTransports
  , stopTransports
  , statusTransports
  -- * Misc
  , Status (..)
  ) where
--------------------------------------------------------------------------------
-- |
-- Module      :  Hummingbird.Internal
-- Copyright   :  (c) Lars Petersen 2017
-- License     :  MIT
--
-- Maintainer  :  info@lars-petersen.net
-- Stability   :  experimental
--------------------------------------------------------------------------------

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Exception
import           Control.Monad
import           Data.Aeson
import           Data.Version
import           System.Exit
import           System.IO


import qualified Network.MQTT.Broker                as Broker
import           Network.MQTT.Broker.Authentication (Authenticator,
                                                     AuthenticatorConfig)
import qualified Network.MQTT.Broker.Authentication as Authentication

import           Hummingbird.Configuration
import qualified Hummingbird.Logging                as Logging
import qualified Hummingbird.Prometheus             as Prometheus
import qualified Hummingbird.SysInfo                as SysInfo
import qualified Hummingbird.Terminator             as Terminator
import qualified Hummingbird.Transport              as Transport

data Hummingbird auth
   = Hummingbird
   { humVersion       :: Version
   , humSettingsPath  :: FilePath
   , humBroker        :: Broker.Broker auth
   , humConfig        :: MVar (Config auth)
   , humAuthenticator :: MVar auth
   , humTransport     :: MVar (Async ())
   , humTerminator    :: MVar (Async ()) -- ^ Session termination thread
   , humSysInfo       :: MVar (Async ()) -- ^ Sys info publishing thread
   , humPrometheus    :: MVar (Async ()) -- ^ Prometheus service thread
   }

-- | The status of a worker thread.
data Status
   = Running
   | Stopped
   | StoppedWithException SomeException

-- | Create a new broker and execute the handler function in the current thread.
new :: (Authenticator auth, FromJSON (AuthenticatorConfig auth)) => Version -> FilePath -> IO (Hummingbird auth)
new version settingsPath = do
  -- Load the config from file.
  config <- loadConfigFromFile settingsPath >>= \case
      Left e       -> hPutStrLn stderr e >> exitFailure
      Right config -> pure config

  Logging.setup (logging config)

  mconfig        <- newMVar config
  mauthenticator <- newMVar =<< Authentication.newAuthenticator (auth config)

  broker <- Broker.newBroker (readMVar mauthenticator)

  mterminator    <- newMVar =<< async (Terminator.run broker)
  mtransports    <- newMVar =<< async (Transport.run broker $ transports config)
  msysinfo       <- newMVar =<< async (SysInfo.run broker)
  mprometheus    <- newMVar =<< async (Prometheus.run $ prometheus config)

  pure Hummingbird {
     humVersion       = version
   , humSettingsPath  = settingsPath
   , humBroker        = broker
   , humConfig        = mconfig
   , humAuthenticator = mauthenticator
   , humTransport     = mtransports
   , humTerminator    = mterminator
   , humSysInfo       = msysinfo
   , humPrometheus    = mprometheus
   }

start :: Authenticator auth => Hummingbird auth -> IO ()
start hum = do
  startSysInfo    hum
  startTransports hum
  startTerminator hum
  startPrometheus hum

stop  :: Hummingbird auth -> IO ()
stop hum = do
  stopSysInfo    hum
  stopTransports hum
  stopTerminator hum
  stopPrometheus hum

startTerminator :: Hummingbird auth -> IO ()
startTerminator hum =
  startThread (humTerminator hum) (Terminator.run $ humBroker hum)

stopTerminator :: Hummingbird auth -> IO ()
stopTerminator hum = stopThread (humTerminator hum)

startPrometheus :: Hummingbird auth -> IO ()
startPrometheus hum = do
  config <- readMVar (humConfig hum)
  startThread (humTerminator hum) (Prometheus.run $ prometheus config)

stopPrometheus :: Hummingbird auth -> IO ()
stopPrometheus hum =
  stopThread (humTerminator hum)

startSysInfo :: Hummingbird auth -> IO ()
startSysInfo hum =
  startThread (humSysInfo hum) (SysInfo.run $ humBroker hum)

stopSysInfo :: Hummingbird auth -> IO ()
stopSysInfo hum =
  stopThread (humSysInfo hum)

getConfig :: Hummingbird auth -> IO (Config auth)
getConfig hum =
  readMVar (humConfig hum)

reloadConfig :: (FromJSON (AuthenticatorConfig auth)) => Hummingbird auth -> IO (Either String (Config auth))
reloadConfig hum =
  modifyMVar (humConfig hum) $ \config->
    loadConfigFromFile (humSettingsPath hum) >>= \case
      Left  e -> pure (config, Left e)
      Right config' -> pure (config', Right config')

restartAuthenticator :: Authenticator auth => Hummingbird auth -> IO ()
restartAuthenticator hum = do
  config <- readMVar (humConfig hum)
  authenticator <- Authentication.newAuthenticator (auth config)
  void $ swapMVar (humAuthenticator hum) authenticator

startTransports :: Authenticator auth => Hummingbird auth -> IO ()
startTransports hum =
  modifyMVar_ (humTransport hum) $ \asnc->
    poll asnc >>= \case
      -- Is already running. Leave as is.
      Nothing -> pure asnc
      Just _  -> do
        config <- readMVar (humConfig hum)
        async $ Transport.run (humBroker hum) (transports config)

stopTransports :: Hummingbird auth -> IO ()
stopTransports hum =
  stopThread (humTransport hum)

statusTransports :: Hummingbird auth -> IO Status
statusTransports hum =
  withMVar (humTransport hum) $ poll >=> \case
    Nothing -> pure Running
    Just x  -> case x of
      Right () -> pure Stopped
      Left  e  -> pure (StoppedWithException e)

stopThread :: MVar (Async ()) -> IO ()
stopThread m =
  withMVar m cancel

startThread :: MVar (Async ()) -> IO () -> IO ()
startThread m t =
  modifyMVar_ m $ \asnc-> poll asnc >>= \case
    -- Is already running. Leave as is.
    Nothing -> pure asnc
    -- Is not running (anymore). Start!
    Just _  -> async t