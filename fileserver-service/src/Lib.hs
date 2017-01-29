
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Lib (startApp) where

import           Control.Concurrent           (forkIO, threadDelay)
import           Control.Monad                (when)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except   (ExceptT)
import           Control.Monad.Trans.Resource
import           Data.Aeson
import           Data.Aeson.TH
import           Data.Bson.Generic
import qualified Data.ByteString.Lazy         as L
import qualified Data.List                    as DL
import           Data.Maybe                   (catMaybes)
import           Data.Time.Clock              (UTCTime, getCurrentTime)
import           Data.Time.Format             (defaultTimeLocale, formatTime)
import           GHC.Generics
import           Network.HTTP.Client          (Manager,defaultManagerSettings,
                                               newManager)
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Network.Wai.Logger
import           Servant
import qualified Servant.API                  as SC
import qualified Servant.Client               as SC
import           System.Log.Formatter
import           System.Log.Handler           (setFormatter)
import           System.Log.Handler.Simple
import           System.Log.Handler.Syslog
import           System.Log.Logger
import           FileserverAPI
import           AuthAPI                      (TokenData(..))
import           System.Directory             (doesFileExist)
import           Database.MongoDB
import           System.Environment           (getProgName)
import           MongoDb                      (drainCursor, runMongo, logLevel)
import           Frequent
import qualified Data.ByteString.Base64 as B64
import           Data.ByteString.UTF8         (toString,fromString)
import           MongoDb


startApp :: Int -> IO ()
startApp sPort = withLogging $ \ aplogger -> do
  warnLog "Starting File Server Service"
  forkIO $ taskScheduler 5
  let settings = setPort sPort $ setLogger aplogger defaultSettings
  runSettings settings app


taskScheduler :: Int -> IO ()
taskScheduler delay = do
  warnLog $ "Task scheduler operating."
  threadDelay $ delay * 1000000
  taskScheduler delay


runReplicator :: UpPayload -> IO ()
runReplicator file = do
  manager <- newManager defaultManagerSettings
  liftIO $ forkIO $ replicateFile file manager
  print "Ran replicator"


-- Replicate file to another file-server node in the network
replicateFile :: UpPayload -> Manager -> IO ()
replicateFile file manager = do
  response <- (SC.runClientM (upload file) (SC.ClientEnv manager (SC.BaseUrl SC.Http "localhost" 8001 ""))) -- Hard coded node to replicate to.
  print "replicated to new node"


app :: Application
app = serve fsAPI server


server :: Server APIfs
server = store :<|> download
  where

    -- Store file payload in the bucket within the service
    store :: UpPayload -> Handler ResponseData
    store file@(UpPayload e_session_key path e_filedata) = liftIO $ do
      let token = getTokenData e_session_key
      case token of
        Just t -> do
                  systemt <- systemTime
                  let expiry = convertTime $ expiryTime t
                  let sys = convertTime systemt

                  -- If the token is out of date, fling the user out of the system
                  if (sys < expiry)
                    then do
                      doc <- runMongo $ do
                          docs <- find (select ["filename" =: path] "FILE_STORE") >>= drainCursor
                          return docs

                      -- if we don't see that the file is saved we will add it
                      if (null doc)
                        then do
                          runMongo $ upsert (select ["filename" =: path] "FILE_STORE") ["filename" =: path]
                          writeFile ("bucket/" ++ path) (extract e_filedata)
                          runReplicator file
                          return ResponseData{ message = "file has been saved", saved = True}
                        else
                          return ResponseData{ message = "file has been saved", saved = True}
                    else
                      return ResponseData{ message = "expired token", saved = False}

        Nothing -> return ResponseData{ message = "invalid token", saved = False}


    --  Supply a path and get the encrypted file in the response payload
    download :: DownRequest -> Handler DownPayload
    download msg@(DownRequest filepath session_key ) = liftIO $ do
      let token = getTokenData session_key
      case token of
        Just t -> do
                  systemt <- systemTime
                  let expiry = convertTime $ expiryTime t
                  let sys = convertTime systemt

                  if (sys < expiry)
                    then do
                      present <- liftIO $ doesFileExist ("bucket/" ++ filepath)
                      if present
                        then do
                          file <- liftIO $ readFile ("bucket/" ++ filepath)
                          let encrypted_file = toString $ B64.encode (encrypt secretKey (fromString file))
                          liftIO $ return DownPayload{ filename = filepath, e_data = encrypted_file}
                        else
                          return DownPayload{ filename = "File doesn't exist", e_data = ""}
                    else
                      return DownPayload{ filename = "", e_data = ""}

        -- unauthorised
        Nothing -> return DownPayload{ filename = "", e_data = ""}


-- global logging functions
debugLog, warnLog, errorLog :: String -> IO ()
debugLog = doLog debugM
warnLog  = doLog warningM
errorLog = doLog errorM
noticeLog = doLog noticeM

doLog f s = getProgName >>= \ p -> do
                t <- getCurrentTime
                f p $ (iso8601 t) ++ " " ++ s

withLogging act = withStdoutLogger $ \aplogger -> do

  lname  <- getProgName
  llevel <- logLevel
  updateGlobalLogger lname
                     (setLevel $ case llevel of
                                  "WARNING" -> WARNING
                                  "ERROR"   -> ERROR
                                  _         -> DEBUG)
  act aplogger
