{-# LANGUAGE TypeApplications #-}
module Tests.Config (test) where

import qualified Control.Monad.Trans.FastWriter as Writer
import qualified Data.Aeson as Aeson
import           Data.Aeson.Config (load)
import qualified Data.Aeson.Diff as AesonDiff
import qualified Data.Aeson.Encode.Pretty as AesonPretty
import qualified Data.ByteString.Lazy.Char8 as LBSChar
import           Data.Proxy (Proxy(..), asProxyTypeOf)
import           Lamdu.Config (Config)
import           Lamdu.Config.Folder (HasConfigFolder(..), getFiles)
import           Lamdu.Config.Theme (Theme)
import           Lamdu.I18N.Language (Language)
import qualified Lamdu.Paths as Paths

import           Test.Lamdu.Prelude

test :: Test
test =
    do
        verifyJson (Proxy @Config) "config.json"
        verifyConfigFolder (Proxy @Theme)
        verifyConfigFolder (Proxy @Language)
    & testCase "config-parses"

verifyConfigFolder ::
    (HasConfigFolder a, Aeson.FromJSON a, Aeson.ToJSON a) =>
    Proxy a -> IO ()
verifyConfigFolder p = getFiles p >>= traverse_ (verifyJson p)

verifyJson :: (Aeson.FromJSON t, Aeson.ToJSON t) => Proxy t -> FilePath -> IO ()
verifyJson proxy jsonPath =
    do
        configPath <- Paths.getDataFileName jsonPath
        json <- load configPath & Writer.evalWriterT
        case Aeson.fromJSON json <&> (`asProxyTypeOf` proxy) of
            Aeson.Error msg -> assertString ("Failed decoding " <> configPath <> " from json: " <> msg)
            Aeson.Success val
                | rejson == json -> pure ()
                | otherwise ->
                    assertString ("json " <> configPath <> " contains unexpected data:\n" <>
                        LBSChar.unpack (AesonPretty.encodePretty (Aeson.toJSON (AesonDiff.diff rejson json))))
                where
                    rejson = Aeson.toJSON val
