{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Lib where

import           Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVar,
                                              readTVar, writeTVar)
import           Control.Exception           (bracket)
import           Control.Monad.IO.Class      (liftIO)
import           Control.Monad.STM           (atomically)
import           Control.Monad.Trans.Reader  (ReaderT, ask, runReaderT)
import           Data.Aeson                  (FromJSON, ToJSON (..), object,
                                              (.=))
import           Data.List                   (nub)
import           Data.Time                   (defaultTimeLocale, parseTimeM)
import           Data.Time.Clock             (UTCTime)
import           Data.Time.Clock.POSIX       (utcTimeToPOSIXSeconds)
import           GHC.Generics                (Generic)
import           Network.HTTP.Client         (defaultManagerSettings,
                                              newManager)
import           Network.Wai.Handler.Warp    (defaultSettings, run, runSettings,
                                              setLogger, setPort)
import           Network.Wai.Logger          (withStdoutLogger)
import           Servant

import qualified Data.HashMap                as M
import qualified Data.Text                   as T

-- Types --
--

type DeviceId = String
type Timestamp = Int

data Ping = Ping
    { pDeviceId  :: DeviceId
    , pTimestamp :: Timestamp
    } deriving (Show, Eq, Generic)

type DevicePings = M.Map DeviceId [Timestamp]

instance ToJSON Ping

instance ToJSON DevicePings where
    toJSON hm = object $ (\a -> (T.pack $ fst a) .= (snd a)) <$> (M.toList hm)

type APIPostPing = Capture "deviceId" String :> Capture "timestamp" Int :> Post '[JSON] NoContent
type APIPostClear = "clear_data" :> Post '[JSON] NoContent

type APIGetPings1 = "all"
                 :> Capture "from" String
                 :> Capture "to" String
                 :> Get '[JSON] DevicePings

type APIGetPings2 = "all"
                 :> Capture "date" String
                 :> Get '[JSON] DevicePings

type APIGetPings3 = Capture "deviceId" String
                 :> Capture "from" String
                 :> Capture "to" String
                 :> Get '[JSON] [Timestamp]

type APIGetPings4 = Capture "deviceId" String
                 :> Capture "date" String
                 :> Get '[JSON] [Timestamp]


type APIGetAll = "all" :> Get '[JSON] DevicePings
type APIGetDevices = "devices" :> Get '[JSON] [DeviceId]

type APIPingers = APIPostPing
             :<|> APIPostClear
             :<|> APIGetPings1
             :<|> APIGetPings2
             :<|> APIGetPings3
             :<|> APIGetPings4
             :<|> APIGetAll
             :<|> APIGetDevices

data PingState = PingState { pings :: TVar [Ping] }

type AppM = ReaderT PingState Handler

-- Helper functions --
--

dateEpochOrZero s = case d of
                      Just i  -> i
                      Nothing -> 0
    where t = parseTimeM True defaultTimeLocale "%Y-%m-%d" s :: Maybe UTCTime
          d = (fromIntegral . round . utcTimeToPOSIXSeconds) <$> t

extractPingsUniqueComponent f s = nub $ foldl (\b a -> (f a) : b) [] s

maybeDeviceId d a = case d of
                      (Just d') -> d' == a
                      Nothing   -> True

extractDeviceIds :: [Ping] -> [DeviceId]
extractDeviceIds p = extractPingsUniqueComponent pDeviceId p

extractTimestamps :: [Ping] -> [Timestamp]
extractTimestamps = extractPingsUniqueComponent pTimestamp

extractDevicePingsRange :: Maybe DeviceId -> Int -> Int -> [Ping] -> [Ping]
extractDevicePingsRange d s e ps = filter f ps
    where f = (\a -> (pTimestamp a) >= s && (pTimestamp a) < e && maybeDeviceId d (pDeviceId a))

extractDevicePingsRangeTS :: Maybe DeviceId -> Int -> Int -> [Ping] -> [Timestamp]
extractDevicePingsRangeTS d s e ps = extractTimestamps $ extractDevicePingsRange d s e ps

extractDevicePingsTSHM :: [Ping] -> DevicePings
extractDevicePingsTSHM = foldl (\b a -> M.insertWithKey (\_ -> (++)) (pDeviceId a) ([pTimestamp a]) b) (M.empty :: DevicePings)

strToEpoch :: String -> Int
strToEpoch s = case '-' `elem` s of
                   True  -> dateEpochOrZero s
                   False -> read s

-- Endpoint logic --
--

postPing :: String -> Int -> AppM NoContent
postPing d i = do
    ps <- ask
    let p = Ping d i
    liftIO $ atomically $ readTVar (pings ps) >>= writeTVar (pings ps) . (p :)
    return NoContent

postClear :: AppM NoContent
postClear = do
    ps <- ask
    liftIO $ atomically $ modifyTVar (pings ps) (const [])
    return NoContent

getDevices :: AppM [DeviceId]
getDevices = do
    ps <- ask
    liftIO $ atomically $ extractDeviceIds <$> (readTVar (pings ps))

getAll :: AppM DevicePings
getAll = do
    ps <- ask
    liftIO $ atomically $ extractDevicePingsTSHM <$> (readTVar (pings ps))

getPings1 :: String -> String -> AppM DevicePings
getPings1 ts te = do
    let its = strToEpoch ts
    let ite = strToEpoch te
    ps <- ask
    liftIO $ atomically $ (extractDevicePingsTSHM . (extractDevicePingsRange Nothing its ite)) <$> (readTVar (pings ps))

getPings2 :: String -> AppM DevicePings
getPings2 ts = do
    let its = strToEpoch ts
    let ite = its + 86400
    ps <- ask
    liftIO $ atomically $ (extractDevicePingsTSHM . (extractDevicePingsRange Nothing its ite)) <$> (readTVar (pings ps))

getPings3 :: String -> String -> String -> AppM [Timestamp]
getPings3 did ts te = do
    let its = strToEpoch ts
    let ite = strToEpoch te
    ps <- ask
    liftIO $ atomically $ (extractDevicePingsRangeTS (Just did) its ite) <$> (readTVar (pings ps))

getPings4 :: String -> String -> AppM [Timestamp]
getPings4 did ts = do
    let its = strToEpoch ts
    let ite = its + 86400
    ps <- ask
    liftIO $ atomically $ (extractDevicePingsRangeTS (Just did) its ite) <$> (readTVar (pings ps))

server :: ServerT APIPingers AppM
server = postPing
    :<|> postClear
    :<|> getPings1
    :<|> getPings2
    :<|> getPings3
    :<|> getPings4
    :<|> getAll
    :<|> getDevices

-- Server Boilerplate --
--

api :: Proxy APIPingers
api = Proxy

nt :: PingState -> AppM a -> Handler a
nt s x = runReaderT x s

app :: PingState -> Application
app s = serve api $ hoistServer api (nt s) server

startApp :: IO()
startApp = do
    let port = 3000
    mgr <- newManager defaultManagerSettings
    initialPings <- atomically $ newTVar []
    putStrLn $ "-- Running Tanda Pingers Challenger <<pingershv2>> @ localhost:" ++ (show port) ++ " --"
    withStdoutLogger $ \aplogger -> do
        let settings = setPort port $ setLogger aplogger defaultSettings
        runSettings settings $ app (PingState initialPings)
