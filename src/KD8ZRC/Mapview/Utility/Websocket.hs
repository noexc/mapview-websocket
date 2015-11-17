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
import Control.Exception (finally)
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import KD8ZRC.Mapview.Types
import qualified Network.WebSockets as WS

type Client = (String, WS.Connection)
type ServerState = [Client]

data WebsocketServer = WebsocketServer (MVar ServerState)

initWebsocketServer :: String -> Int -> IO WebsocketServer
initWebsocketServer host port = do
  m <- newMVar []
  let s = WebsocketServer m
  _ <- forkIO (startServer s host port)
  return s

startServer :: WebsocketServer -> String -> Int -> IO ()
startServer (WebsocketServer st) host port =
  WS.runServer host port $ application st

addClient :: Client -> ServerState -> ServerState
addClient = (:)

removeClient :: Client -> ServerState -> ServerState
removeClient client = filter ((/= fst client) . fst)

broadcast :: T.Text -> ServerState -> IO ()
broadcast message clients = do
  T.putStrLn message
  forM_ (map snd clients) (`WS.sendTextData` message)

application :: MVar ServerState -> WS.ServerApp
application st pending = do
  conn <- WS.acceptRequest pending
  uuid <- UUIDv4.nextRandom
  putStrLn $ "New client: " ++ UUID.toString uuid
  let client = (UUID.toString uuid, conn)
  flip finally (disconnect client) $ do
    liftIO $ modifyMVar_ st $ \s -> do
      let s' = addClient client s
      WS.sendTextData (snd client) ("Welcome!" :: T.Text)
      broadcast "someone joined" s'
      return s'
    return ()
  where
    disconnect client = do
      s <- modifyMVar st $ \s ->
        let s' = removeClient client s in return (s', s')
      broadcast "someone disconnected" s

broadcastRaw :: WebsocketServer -> PacketLineCallback t
broadcastRaw (WebsocketServer w) =
  PacketLineCallback (
    \s -> do
      clients <- liftIO $ readMVar w
      liftIO (broadcast (T.pack s) clients))
