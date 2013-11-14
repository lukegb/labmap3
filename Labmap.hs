{-# LANGUAGE OverloadedStrings, MultiWayIf, LambdaCase, RecordWildCards #-}

module Main where

import Labmap.Common
import Labmap.Conf
import Labmap.GetUser
import Labmap.Lock
import Labmap.Scanner
import Labmap.Users
import Labmap.Util

import Control.Applicative
import Control.Concurrent
import Control.DeepSeq
import Control.Monad
import Control.Monad.Trans
import Data.Aeson
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import qualified Data.Map.Strict as M
import Network.Wai.Middleware.Static
import Options.Applicative
import System.Log.Logger
import Web.Scotty as S

opts :: ParserInfo (IO ())
opts = info (helper <*> args) (fullDesc <> header "Labmap 3.0")
  where
    args = subparser $ 
      command "getuser" (info (pure getUserCommand) idm) <>
      command "server" (info (serverCommand <$>
        strOption (short 'c' <> value "labmap.conf" <> help "The configuration file to use."))
        (progDesc "Start the Labmap web server.") )

main :: IO ()
main = join $ execParser opts

sleepTime :: Int -> Int -> IO (Maybe NominalDiffTime)
sleepTime open close = do
  now@(ZonedTime (LocalTime day (TimeOfDay h _ _)) tz) <- getZonedTime
  return $ do
    wakeDay <- if
      | h < open -> Just day
      | h >= close -> Just (addDays 1 day)
      | otherwise -> Nothing
    let wakeTime = ZonedTime (LocalTime wakeDay (TimeOfDay open 0 0)) tz
    return $ zonedTimeToUTC wakeTime `diffUTCTime` zonedTimeToUTC now


getUserCommand :: IO ()
getUserCommand = getUser >>= print

type LabState = Either Text (M.Map Text Value)

makeResult :: Cached Users -> ( Text, Maybe MachineState ) -> IO Value
makeResult _ ( _, Nothing ) = return "UNKNOWN"
makeResult _ ( _, Just Available ) = return "AVAILABLE"
makeResult users ( m, Just (Occupied u) ) = do
  m'ui <- M.lookup u <$> getCached users
  
  case m'ui of
    Nothing -> return "UNKNOWN"
    Just ui -> do
      let resf = [ "username" .= u
               , "fullName" .= fullName ui
               , "photo" .= photo ui
               , "groups" .= groups ui
               ]
      e'le <- lastEntryForMachine m
      object <$> case e'le of
        Left e
          -> warningM "labmap" ("Failed to check lock status:" ++ e) >> return resf
        Right le | lockUser le == u -> do
          now@(ZonedTime _ tz) <- getZonedTime
          let lt = ZonedTime (lockTime le) tz
          let td = (zonedTimeToUTC now `diffUTCTime` zonedTimeToUTC lt) - fromIntegral (lockDuration le * 60)
          return $ if td < 30 * 60
            then resf ++
            [ "lockTime" .= lt
            , "lockDuration" .= lockDuration le
            ]
            else resf
        _ -> return resf

scanForever :: LabmapConf -> Cached Users -> MVar LabState -> IO ()
scanForever LabmapConf{..} users labState = do
  resultChan <- newChan
  noticeM "labmap" "Starting scan."
  runVar <- newMVar ()
  scan sshOpts machines runVar resultChan scanThreads
  forever $ do
    sleepTime openingHour closingHour >>= \case
      Just s -> do
        let t = round (s * 1000000)
        infoM "labmap" ("Sleeping for " ++ show t ++ " microseconds")
        swapMVar labState (Left "CLOSED")
        -- confiscate the runvar while we sleep, this will block the scanner threads
        withMVar runVar $ const (threadDelay t)
        infoM "labmap" "Woke up"
      Nothing -> return ()
    ( m, s ) <- readChan resultChan
    s' <- makeResult users ( m, s )
    debugM "labmap" (T.unpack m <> ": " <> show s)
    modifyMVar_ labState $ \ls -> return $!! Right $ case ls of
      Left _ -> M.singleton m s'
      Right state -> M.insert m s' state

serve :: Int -> MVar LabState -> IO ()
serve port labState = do
  noticeM "labmap" "Starting server."
  scotty port $ do
    middleware $ staticPolicy (noDots >-> addBase "static")

    get "/" $ do
      addHeader "Content-Type" "text/html"
      file "static/index.html"

    get "/labstate" $ do
      s <- liftIO $ readMVar labState
      S.json $ case s of
        Left m -> object ["UNAVAILABLE" .= m]
        Right state -> toJSON state

serverCommand :: String -> IO ()
serverCommand configFile = do
  m'conf <- loadConfig configFile
  case m'conf of
    Nothing -> putStrLn "Could not read configuration file"
    Just conf@LabmapConf{..} -> do
      updateGlobalLogger "labmap" (setLevel logLevel)
      users <- cache (hours usersCacheHours) getAllUsers
      labState <- newMVar (Right $ M.empty)
      forkIO $ scanForever conf users labState
      serve port labState
