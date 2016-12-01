{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Hummingbird.Configuration where

import           Data.Aeson
import           Data.Aeson.Types
import           Data.Functor.Identity
import qualified Data.HashMap.Strict      as HM
import qualified Data.Map                 as M
import           Data.String
import qualified Data.Text                as T
import           Data.Word
import qualified Data.Yaml                as Yaml
import qualified Network.MQTT.RoutingTree as R
import qualified System.Log.Logger        as Log

loadConfigFromFile :: FromJSON auth => FilePath -> IO (Either String (Config auth))
loadConfigFromFile path = do
  ec <- Yaml.decodeFileEither path
  pure $ case ec of
    Left e  -> Left (Yaml.prettyPrintParseException e)
    Right c -> Right c

data Config auth
   = Config
     { servers :: [ServerConfig]
     , logging :: LogConfig
     , auth    :: auth
     }

data ServerConfig
   = SocketServer
     { bindAddress   :: T.Text
     , bindPort      :: Word16
     , listenBacklog :: Int
     }
   | WebSocketServer
     { transport   :: ServerConfig
     }
   | TlsServer
     { tlsTransport      :: ServerConfig
     , tlsWantClientCert :: Bool
     , tlsCaFilePath     :: FilePath
     , tlsCrtFilePath    :: FilePath
     , tlsKeyFilePath    :: FilePath
     }
  deriving (Eq, Ord, Show)

data Privilege
   = Publish
   | Subscribe
   deriving (Eq, Ord, Show)

instance FromJSON Privilege where
  parseJSON (String "PUB") = pure Publish
  parseJSON (String "SUB") = pure Subscribe
  parseJSON _              = fail "Expected 'PUB' or 'SUB'."

instance FromJSON (R.RoutingTree (Identity [Privilege])) where
  parseJSON (Object a) = R.RoutingTree <$> HM.foldlWithKey' f (pure M.empty) a
    where
      f pm k v = do
        m    <- pm
        node <- parseJSON v
        pure $ M.insert (fromString $ T.unpack k) node m
  parseJSON invalid = typeMismatch "RoutingTree" invalid

instance FromJSON (R.RoutingTreeNode (Identity [Privilege])) where
  parseJSON (Object v) = do
    subtree  <- v .:? ">" .!= R.empty
    mpubsub  <- v .:? "!"
    pure $ case mpubsub of
      Nothing -> R.nodeFromTree subtree
      Just pb -> R.nodeFromTreeAndValue subtree (Identity pb)
  parseJSON _ = pure $ R.nodeFromTree R.empty

data LogConfig
   = LogConfig
     { logLevel     :: Log.Priority
     , logAppenders :: [LogAppender]
     } deriving (Eq, Ord, Show)

data LogAppender
   = SyslogAppender
   | ConsoleAppender
   deriving (Eq, Ord, Show)

instance FromJSON auth => FromJSON (Config auth) where
  parseJSON (Object v) = Config
    <$> v .: "servers"
    <*> v .: "logging"
    <*> v .: "auth"
  parseJSON invalid = typeMismatch "Config" invalid

instance FromJSON LogConfig where
  parseJSON (Object v) = LogConfig
    <$> pLevel
    <*> v .: "appenders"
    where
      pLevel = do
        s <- v .: "level" :: Parser String
        case s of
          "DEBUG"     -> pure Log.DEBUG
          "INFO"      -> pure Log.INFO
          "NOTICE"    -> pure Log.NOTICE
          "WARNING"   -> pure Log.WARNING
          "ERROR"     -> pure Log.ERROR
          "CRITICAL"  -> pure Log.CRITICAL
          "ALERT"     -> pure Log.ALERT
          "EMERGENCY" -> pure Log.EMERGENCY
          _           -> fail "Expected DEBUG, INFO, WARNING, ERROR etc."
  parseJSON invalid = typeMismatch "LogConfig" invalid

instance FromJSON LogAppender where
  parseJSON (Object v) = do
    t <- v .: "type" :: Parser String
    case t of
      "syslog"  -> pure SyslogAppender
      "console" -> pure ConsoleAppender
      _         -> fail "Expected 'syslog' or 'console'."
  parseJSON invalid = typeMismatch "LogAppender" invalid

instance FromJSON ServerConfig where
  parseJSON (Object v) = do
    t <- v .: "type" :: Parser String
    case t of
      "socket" -> SocketServer
        <$> v .: "bindAddress"
        <*> v .: "bindPort"
        <*> v .: "listenBacklog"
      "websocket" -> WebSocketServer
        <$> v .: "transport"
      "tls" -> TlsServer
        <$> v .: "transport"
        <*> v .: "wantClientCert"
        <*> v .: "caFilePath"
        <*> v .: "crtFilePath"
        <*> v .: "keyFilePath"
      _ -> fail "Expected 'socket', 'websocket' or 'tls'."
  parseJSON invalid = typeMismatch "ServerConfig" invalid
