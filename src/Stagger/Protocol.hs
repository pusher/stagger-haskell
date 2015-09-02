module Stagger.Protocol where

import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.MessagePack as Msg
import Data.Serialize (
  Get,
  Put,
  Result(..),
  Serialize,
  decode,
  encode,
  get,
  getByteString,
  getWord8,
  getWord16be,
  getWord32be,
  put,
  putByteString,
  putWord8,
  putWord16be,
  putWord32be,
  runGetPartial)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8')
import Data.Word

import Control.Error.Util (hush)
import Control.Monad (when)

import Stagger.Util (eitherToMonad)

data Protocol =
  Protocol {
    protocolMagicBytes :: Word16,
    protocolVersion :: Word8
  }

protocol = Protocol 0x8384 0x00

data Command =
  ReportAllCommand |
  RegisterProcessCommand |
  StatsCompleteCommand
  deriving Show

instance Serialize Command where
  get = do
    byte <- getWord8
    case byte of
      0x30 -> return ReportAllCommand
      0x41 -> return RegisterProcessCommand
      0x43 -> return StatsCompleteCommand
      _ -> fail $ "Unkown command: " ++ show byte

  put ReportAllCommand = putWord8 0x30
  put RegisterProcessCommand = putWord8 0x41
  put StatsCompleteCommand = putWord8 0x43

data Message =
  ReportAllMessage !ReportAll |
  RegisterProcessMessage !RegisterProcess |
  StatsCompleteMessage !Msg.Object -- TODO: create a proper type instead of Object
  deriving Show

instance Serialize Message where
  get = do
    magicBytes <- getWord16be
    when
      (magicBytes /= (protocolMagicBytes protocol))
      (fail $ "Expected magic bytes: " ++ (show $ protocolMagicBytes protocol))
    version <- getWord8
    when
      (version /= (protocolVersion protocol))
      (fail $ "Expected protocol version: " ++ (show $ protocolVersion protocol))
    command <- get
    contentLen <- getWord32be
    content <- getByteString $ fromIntegral contentLen
    case command of
      ReportAllCommand -> ReportAllMessage <$> eitherToMonad (decode content)
      RegisterProcessCommand -> RegisterProcessMessage <$> eitherToMonad (decode content)
      StatsCompleteCommand -> StatsCompleteMessage <$> eitherToMonad (decode content)

  put msg =
    case msg of
      ReportAllMessage content -> put' ReportAllCommand content
      RegisterProcessMessage content -> put' RegisterProcessCommand content
      StatsCompleteMessage content -> put' StatsCompleteCommand content
   where
    put' :: Serialize a => Command -> a -> Put
    put' cmd content = do
      let packedContent = encode content
      putWord16be $ protocolMagicBytes protocol
      putWord8 $ protocolVersion protocol
      put cmd
      putWord32be $ fromIntegral $ B.length packedContent
      putByteString packedContent

data ReportAll =
  ReportAll
    !Word64
  deriving Show

instance Serialize ReportAll where
  get = (get :: Get Msg.Object) >>= (maybe (fail "failed to unpack") return . fromObjReportAll)
   where
    fromObjReportAll :: Msg.Object -> Maybe ReportAll
    fromObjReportAll m = ReportAll <$> (fromObjInteger =<< lookup "Timestamp" =<< getMap m)

  put (ReportAll r) = put $ Msg.ObjectMap $ M.fromList [
      (Msg.ObjectString "Timestamp", Msg.ObjectUInt r)
    ]

data RegisterProcess =
  RegisterProcess
    !(M.Map B.ByteString B.ByteString)
  deriving Show

instance Serialize RegisterProcess where
  get = (get :: Get Msg.Object) >>= (maybe (fail "failed to unpack") return . fromObjRegisterProcess)
   where
    fromObjRegisterProcess :: Msg.Object -> Maybe RegisterProcess
    fromObjRegisterProcess m = RegisterProcess <$> (getByteStringMap =<< lookup "Tags" =<< getMap m)

  put (RegisterProcess p) = put $ Msg.ObjectMap $ M.fromList [
      (Msg.ObjectString "Tags", Msg.ObjectMap $ M.map Msg.ObjectString $ M.mapKeys Msg.ObjectString p)
    ]

fromObjInteger :: Msg.Object -> Maybe Word64
fromObjInteger (Msg.ObjectUInt i) = Just i
fromObjInteger _ = Nothing

getMap :: Msg.Object -> Maybe [(T.Text, Msg.Object)]
getMap (Msg.ObjectMap elems) =
  mapM (\(k, v) -> do
    k' <- fromObjText k
    return (k', v)) (M.toList elems)
getMap _ = Nothing

fromObjText :: Msg.Object -> Maybe T.Text
fromObjText (Msg.ObjectString r) = hush $ decodeUtf8' r
fromObjText _ = Nothing

fromObjByteString :: Msg.Object -> Maybe B.ByteString
fromObjByteString (Msg.ObjectString r) = Just r
fromObjByteString _ = Nothing

getByteStringMap :: Msg.Object -> Maybe (M.Map B.ByteString B.ByteString)
getByteStringMap (Msg.ObjectMap elems) =
  M.fromList <$>
    mapM
      (\(k, v) -> (,) <$> fromObjByteString k <*> fromObjByteString v)
      (M.toList elems)
