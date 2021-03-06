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

module FileserverAPI where

import           Data.Aeson
import           Data.Aeson.TH
import           GHC.Generics
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Servant
import           Servant.API
import           Servant.Client


data UpPayload = UpPayload { e_session_key :: String
                           , path :: String
                           , e_filedata :: String
                       } deriving (Generic, FromJSON, ToJSON)


data ResponseData = ResponseData { saved :: Bool
                                 } deriving (Generic, ToJSON, FromJSON)


data DownPayload = DownPayload { filename :: String
                               , e_data :: String
                             } deriving (Generic, ToJSON, FromJSON)

data DownRequest = DownRequest { filepath :: String,
                                 session_key :: String
                               } deriving (Generic, FromJSON, ToJSON)


type APIfs = "store" :> ReqBody '[JSON] UpPayload :> Post '[JSON] ResponseData
        :<|> "download" :> ReqBody '[JSON] DownRequest :> Post '[JSON] DownPayload

fsAPI :: Proxy APIfs
fsAPI = Proxy


upload :: UpPayload -> ClientM ResponseData
getFile :: DownRequest -> ClientM DownPayload

(upload :<|> getFile) = client fsAPI
