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
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import KD8ZRC.Mapview.Types
import qualified Network.WebSockets as WS

type Client = (String, Chan.Chan T.Text)
type ServerState = [Client]

data WebsocketServer = WebsocketServer (MVar ServerState)

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
initWebsocketServer :: Chan.Chan T.Text -> String -> Int -> IO ()
initWebsocketServer chan host port = do
  m <- newMVar []
  _ <- forkIO (broadcast chan m)
  WS.runServer host port (application m)

addClient :: Client -> ServerState -> ServerState
addClient = (:)

removeClient :: Client -> ServerState -> ServerState
removeClient client = filter ((/= fst client) . fst)

broadcast :: Chan.Chan T.Text -> MVar ServerState -> IO ()
broadcast msg' clients' = forever $ do
  msg <- readChan msg'
  clients <- readMVar clients'
  T.putStrLn msg
  sequence $ (flip Chan.writeChan msg . snd) `fmap` clients

application :: MVar ServerState -> WS.ServerApp
application st pending = do
  conn <- WS.acceptRequest pending
  uuid <- UUIDv4.nextRandom
  chan <- Chan.newChan
  putStrLn $ "New client: " ++ UUID.toString uuid
  let client = (UUID.toString uuid, chan)
  liftIO $ modifyMVar_ st $ \s -> do
    let s' = addClient client s
    return s'
  flip finally (disconnect client) $ forever $ do
    msg <- readChan chan
    WS.sendTextData conn msg
  where
    disconnect client = do
      modifyMVar st $ \s ->
        let s' = removeClient client s in return (s', s')
      putStrLn $ "Disconnect : " ++ fst client
