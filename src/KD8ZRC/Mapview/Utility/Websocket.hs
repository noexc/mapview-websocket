{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
-- |
-- Module : KD8ZRC.Mapview.Utility.Websocket
-- Copyright : (C) 2015 Ricky Elrod
-- License : MIT (see LICENSE file)
-- Maintainer : Ricky Elrod <ricky@elrod.me>
-- Stability : experimental
-- Portability : ghc
--
-- Provides websocket callbacks for mapview 3.0+
----------------------------------------------------------------------------
module KD8ZRC.Mapview.Utility.Websocket where

import Control.Concurrent
import qualified Control.Concurrent.Chan as Chan
import Control.Exception (finally)
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import KD8ZRC.Mapview.Types
import qualified Network.WebSockets as WS

type Client = (String, Chan.Chan BS.ByteString)
type ServerState = [Client]

data WebsocketServer = WebsocketServer (MVar ServerState)

-- | These callbacks get called when a client connects to the websocket. They
-- can be used to send a welcome message of sorts, or more practically, a
-- history of previous downlink packet information.
newtype WebsocketOnConnectCallback =
  WebsocketOnConnectCallback (Client -> IO ())

-- | A simple wrapper to call a 'WebsocketOnConnectCallback' with a given
-- 'Client'.
callOnConnectCallback
  :: WebsocketOnConnectCallback
  -> Client
  -> IO ()
callOnConnectCallback (WebsocketOnConnectCallback f) c = f c

-- | To make use of @mapview-websocket@ in your MapView application, start off
-- by initializing a new 'Chan.Chan T.Text'. To do this, in your @main@'
-- function, write @rawChan <- Chan.newChan@. This should get passed to your
-- 'MapviewConfig' and sent to 'writeChanRaw' in your '_mvPacketLineCallback'
-- list.
--
-- Now you can start a 'WebsocketServer'. Still in @main@, fork a
-- 'WebsocketServer' by doing (something like)
-- @_ <- forkIO $ initWebsocketServer rawChan "127.0.0.1" 8181@, changing the
-- hostname and port number to bind to, as necessary.
--
-- As MapView updates @rawChan@ (via the 'writeChanRaw' callback),
-- @mapview-websocket@ will see the updates and broadcast them to clients as
-- soon as it can.
initWebsocketServer
  :: Chan.Chan BS.ByteString
  -> String
  -> Int
  -> [WebsocketOnConnectCallback]
  -> IO ()
initWebsocketServer chan host port occs = do
  m <- newMVar []
  _ <- forkIO (broadcast chan m)
  WS.runServer host port (application m occs)

addClient :: Client -> ServerState -> ServerState
addClient = (:)

removeClient :: Client -> ServerState -> ServerState
removeClient client = filter ((/= fst client) . fst)

broadcast :: Chan.Chan BS.ByteString -> MVar ServerState -> IO ()
broadcast msg' clients' = forever $ do
  msg <- readChan msg'
  clients <- readMVar clients'
  sequence $ (flip Chan.writeChan msg . snd) `fmap` clients

application :: MVar ServerState -> [WebsocketOnConnectCallback] -> WS.ServerApp
application st occs pending = do
  conn <- WS.acceptRequest pending
  uuid <- UUIDv4.nextRandom
  chan <- Chan.newChan
  putStrLn $ "New client: " ++ UUID.toString uuid
  let client = (UUID.toString uuid, chan)
  mapM_ (flip callOnConnectCallback client) occs
  liftIO $ modifyMVar_ st $ \s -> do
    let s' = addClient client s
    return s'
  flip finally (disconnect client) $ forever $ do
    msg <- readChan chan
    WS.sendTextData conn (T.decodeUtf8 msg)
  where
    disconnect client = do
      modifyMVar st $ \s ->
        let s' = removeClient client s in return (s', s')
      putStrLn $ "Disconnect : " ++ fst client
