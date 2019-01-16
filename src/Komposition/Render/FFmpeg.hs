{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DisambiguateRecordFields   #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
module Komposition.Render.FFmpeg
  ( runFFmpegRender
  , extractFrameToFile'
  )
where

import           Komposition.Prelude            hiding (bracket)
import qualified Prelude

import           Control.Effect
import           Control.Effect.Carrier
import           Control.Effect.Sum
import           Control.Lens
import qualified Data.List.NonEmpty             as NonEmpty
import           Data.Vector                    (Vector)
import qualified Data.Vector                    as Vector
import           Pipes.Safe                     (bracket)
import           System.Directory
import           System.FilePath
import           System.IO.Temp
import           System.Process.Typed
import           Text.Printf

import           Komposition.Duration
import           Komposition.FFmpeg.Command     (Command (Command))
import qualified Komposition.FFmpeg.Command     as Command
import           Komposition.FFmpeg.Process
import           Komposition.Library
import           Komposition.MediaType
import           Komposition.Progress
import           Komposition.Render
import           Komposition.Render.Composition (Composition (..))
import qualified Komposition.Render.Composition as Composition
import           Komposition.Timestamp
import           Komposition.VideoSettings
import           Komposition.VideoSpeed

data Input mt where
  VideoAssetInput :: FilePath -> Input Video
  AudioAssetInput :: FilePath -> Input Audio
  StillFrameInput :: FilePath -> Duration -> Input Video
  SilenceInput :: Duration -> Input Audio

deriving instance Eq (Input mt)
deriving instance Show (Input mt)

newtype InputIndex = InputIndex Integer
  deriving (Show)

type PartStreamName = Text

data PartStream mt where
  VideoClipStream :: InputIndex -> TimeSpan -> VideoSpeed -> PartStream Video
  AudioClipStream :: InputIndex -> TimeSpan -> PartStream Audio
  StillFrameStream :: InputIndex -> PartStream Video
  SilenceStream :: Duration -> PartStream Audio

deriving instance Show (PartStream mt)

data CommandInput mt where
  VideoCommandInput :: NonEmpty (Input Video) -> NonEmpty (PartStreamName, PartStream Video) -> CommandInput Video
  AudioCommandInput :: [Input Audio] -> NonEmpty (PartStreamName, PartStream Audio) -> CommandInput Audio

type family Inputs mt where
  Inputs Video = NonEmpty (Input Video)
  Inputs Audio = [Input Audio]

inputs :: CommandInput mt -> Inputs mt
inputs (VideoCommandInput is _) = is
inputs (AudioCommandInput as _) = as

inputStreams :: CommandInput mt -> NonEmpty (PartStreamName, PartStream mt)
inputStreams (VideoCommandInput _ ss) = ss
inputStreams (AudioCommandInput _ ss) = ss

toCommandInput
  :: SMediaType mt
  -> FilePath
  -> VideoSettings
  -> Source mt
  -> Int
  -> NonEmpty (Composition.CompositionPart mt)
  -> IO (CommandInput mt)
toCommandInput mediaType tmpDir videoSettings source startAt parts' =
  parts'
    & NonEmpty.zip (startAt :| [succ startAt..])
    & traverse (toPartStream mediaType source)
    & (`runStateT` mempty)
    & (>>= toCommandInputOrPanic mediaType)
  where
    toInputIndex i = InputIndex (fromIntegral (i + startAt))
    addUniqueInput ::
         Eq (Input mt) => Input mt -> StateT (Vector (Input mt)) IO InputIndex
    addUniqueInput input = do
      is <- get
      case Vector.findIndex (== input) is of
        Just idx -> return (toInputIndex (fromIntegral idx))
        Nothing -> do
          put (is `Vector.snoc` input)
          return (toInputIndex (Vector.length is))
    toPartStream mediaType' source' (i, p) =
      case (mediaType', i, p) of
        (SVideo, vi, Composition.VideoClip asset ts speed) -> do
          ii <- addUniqueInput (VideoAssetInput (videoAssetSourcePath source' asset))
          return ("v" <> show vi, VideoClipStream ii ts speed)
        (SVideo, vi, Composition.StillFrame mode asset ts duration') -> do
          frameFile <-
            lift (extractFrameToFile' videoSettings mode source' asset ts tmpDir)
          ii <- addUniqueInput (StillFrameInput frameFile duration')
          return ("v" <> show vi, StillFrameStream ii)
        (SAudio, ai, Composition.AudioClip asset) -> do
          ii <- addUniqueInput (AudioAssetInput (asset ^. assetMetadata . path . unOriginalPath))
          return
            ("a" <> show ai, AudioClipStream ii (TimeSpan 0 (durationOf AdjustedDuration asset)))
        (SAudio, ai, Composition.Silence d) ->
          return ("a" <> show ai, SilenceStream d)
    toCommandInputOrPanic :: SMediaType mt -> (NonEmpty (PartStreamName, PartStream mt), Vector (Input mt)) -> IO (CommandInput mt)

    toCommandInputOrPanic SVideo (streams, is) = do
      is' <-
        maybe
          (panic "No inputs found for FFmpeg command.")
          pure
          (NonEmpty.nonEmpty (Vector.toList is))
      pure (VideoCommandInput is' streams)
    toCommandInputOrPanic SAudio (streams, is) =
      pure (AudioCommandInput (Vector.toList is) streams)

toRenderCommand
  :: VideoSettings
  -> Command.Output
  -> CommandInput Video
  -> CommandInput Audio
  -> Command
toRenderCommand videoSettings output videoInput audioInput =
  Command
  { output = output
  -- NOTE: We know the video inputs are non-empty, so this is safe.
  , inputs = NonEmpty.fromList (toList videoInputs <> audioInputs)
  , filterGraph =
      Just . Command.FilterGraph $
         videoInputChains
         <> audioInputChains
         <> (videoChain :| [audioChain])
  , mappings = [videoStream, audioStream]
  , format =
      case output of
        Command.HttpStreamingOutput{} -> Just "matroska"
        Command.UdpStreamingOutput{}  -> Just "matroska"
        Command.FileOutput{}          -> Just "mp4"
  , vcodec = Just "h264"
  , acodec = Just "aac"
  , frameRate = Just (videoSettings ^. frameRate)
  }
  where
    videoInputs = NonEmpty.map toVideoInput (inputs videoInput)
    audioInputs = mapMaybe toAudioInput (inputs audioInput)
    namedStream n =
      Command.StreamSelector (Command.StreamName n) Nothing Nothing
    videoStream = namedStream "video"
    audioStream = namedStream "audio"
    videoChain = Command.FilterChain (videoConcat :| [videoSetStart])
    audioChain = Command.FilterChain (audioConcat :| [audioSetStart])
    videoInputChains = map toVideoInputChain (inputStreams videoInput)
    audioInputChains = map toAudioInputChain (inputStreams audioInput)
    videoConcat =
      Command.RoutedFilter
        (NonEmpty.toList
           (map (toStreamNameOnlySelector . fst) (inputStreams videoInput)))
        (Command.Concat (fromIntegral (length (inputStreams videoInput))) 1 0)
        []
    audioConcat =
      Command.RoutedFilter
        (NonEmpty.toList
           (map (toStreamNameOnlySelector . fst) (inputStreams audioInput)))
        (Command.Concat (fromIntegral (length (inputStreams audioInput))) 0 1)
        []
    videoSetStart = Command.RoutedFilter [] (Command.SetPTS Command.PTSStart) [videoStream]
    audioSetStart =
      Command.RoutedFilter [] (Command.AudioSetPTS Command.PTSStart) [audioStream]
    --
    -- Conversion helpers:
    --
    toVideoInput :: Input Video -> Command.Source
    toVideoInput =
      \case
        VideoAssetInput p -> Command.FileSource p
        StillFrameInput frameFile duration' ->
          Command.StillFrameSource
            frameFile
            (videoSettings ^. frameRate)
            duration'
    toAudioInput :: Input Audio -> Maybe Command.Source
    toAudioInput =
      \case
        AudioAssetInput p -> Just (Command.FileSource p)
        SilenceInput{} -> Nothing
    toStreamNameOnlySelector streamName =
      Command.StreamSelector (Command.StreamName streamName) Nothing Nothing
    toVideoInputChain ::
         (PartStreamName, PartStream Video) -> Command.FilterChain
    toVideoInputChain (streamName, partStream) =
      case partStream of
        VideoClipStream ii ts (VideoSpeed s) ->
          trimmedIndexedInput Video streamName ii ts (Command.PTSMult
                                                      (Command.PTSDouble (1 / s))
                                                       Command.PTSStart)
        StillFrameStream i ->
          Command.FilterChain
            (Command.RoutedFilter
               [indexedStreamSelector Command.Video i]
               (Command.SetPTS Command.PTSStart)
               [ Command.StreamSelector
                   (Command.StreamName streamName)
                   Nothing
                   Nothing
               ] :|
             [])
    toAudioInputChain ::
         (PartStreamName, PartStream Audio) -> Command.FilterChain
    toAudioInputChain (streamName, ps) =
      case ps of
        AudioClipStream ii ts -> trimmedIndexedInput Audio streamName ii ts Command.PTSStart
        SilenceStream d       ->
          Command.FilterChain
            (Command.RoutedFilter
               []
               (Command.AudioEvalSource d)
               [ Command.StreamSelector
                   (Command.StreamName streamName)
                   Nothing
                   Nothing
               ] :|
             [])
    indexedStreamSelector track (InputIndex i) =
      Command.StreamSelector (Command.StreamIndex i) (Just track) (Just 0)
    trimmedIndexedInput mediaType streamName (InputIndex i) ts ptsExpr =
      case mediaType of
        Video -> Command.FilterChain (trimFilter Command.Video Command.Trim :| [scaleFilter, setPTSFilter (Command.SetPTS ptsExpr)])
        Audio -> Command.FilterChain (trimFilter Command.Audio Command.AudioTrim :| [setPTSFilter (Command.AudioSetPTS ptsExpr)])
      where
        trimFilter track trim =
          Command.RoutedFilter
           [ Command.StreamSelector
               (Command.StreamIndex i)
               (Just track)
               (Just 0)
           ]
           (trim (spanStart ts) (durationOf OriginalDuration ts))
           []
        scaleFilter =
          Command.RoutedFilter
             []
             Command.Scale
             { scaleWidth = videoSettings ^. resolution . width
             , scaleHeight = videoSettings ^. resolution . height
             , scaleForceOriginalAspectRatio =
                 Command.ForceOriginalAspectRatioDisable
             }
             []
        setPTSFilter ptsFilter =
          Command.RoutedFilter
             []
             ptsFilter
             [ Command.StreamSelector
                 (Command.StreamName streamName)
                 Nothing
                 Nothing
             ]

newtype FFmpegRenderC m a = FFmpegRenderC { runFFmpegRenderC :: m a }
  deriving (Functor, Applicative, Monad, MonadIO)

toFFmpegOutput :: Output -> Command.Output
toFFmpegOutput = \case
  FileOutput p -> Command.FileOutput p
  UdpStreamingOutput h p -> Command.UdpStreamingOutput h p
  HttpStreamingOutput h p -> Command.HttpStreamingOutput h p

instance (MonadIO m, Carrier sig m) => Carrier (Render :+: sig) (FFmpegRenderC m) where
  ret = pure
  eff = handleSum (FFmpegRenderC . eff . handleCoercible) $ \case
    RenderComposition videoSettings videoSource (toFFmpegOutput -> target) c@(Composition video audio) k ->
      k $ bracket
        (do
          canonical <- liftIO getCanonicalTemporaryDirectory
          liftIO $ createTempDirectory canonical "komposition.render")
        (liftIO . removeDirectoryRecursive)
        $ \tmpDir -> do
          videoInput <-
            liftIO (toCommandInput SVideo tmpDir videoSettings videoSource 0 video)
          audioInput <-
            liftIO
              (toCommandInput
                 SAudio
                 tmpDir
                 videoSettings
                 AudioOriginal
                 (length (inputs videoInput))
                 audio)
          let renderCmd = toRenderCommand videoSettings target videoInput audioInput
          runFFmpegCommand (ProgressUpdate "Rendering") (durationOf OriginalDuration c) renderCmd
    ExtractFrameToFile videoSettings mode videoSource videoAsset ts frameDir k ->
      k =<< liftIO (extractFrameToFile' videoSettings mode videoSource videoAsset ts frameDir)

videoAssetSourcePath :: Source Video -> Asset Video -> FilePath
videoAssetSourcePath videoSource videoAsset =
  case videoSource of
    VideoTranscoded -> videoAsset ^. videoAssetTranscoded . unProxyPath
    VideoProxy      -> videoAsset ^. videoAssetProxy . unProxyPath

extractFrameToFile' ::
     VideoSettings
  -> Composition.StillFrameMode
  -> Source Video
  -> Asset Video
  -> TimeSpan
  -> FilePath
  -> IO FilePath
extractFrameToFile' videoSettings mode videoSource videoAsset ts frameDir = do
  let sourcePath = videoAssetSourcePath videoSource videoAsset
      frameHash =
        hash
          ( mode
          , videoSource
          , sourcePath
          , videoSettings ^. resolution
          , durationToSeconds (spanStart ts)
          , durationToSeconds (spanEnd ts))
      frameFilePath = frameDir </> show (abs frameHash) <> ".png"
  case mode of
    Composition.FirstFrame ->
      extractFrame sourcePath (spanStart ts) frameFilePath
    Composition.LastFrame ->
      let frameDuration =
            durationFromSeconds (1 / fromIntegral (videoSettings ^. frameRate))
      in extractFrame sourcePath (spanEnd ts - frameDuration) frameFilePath
  return frameFilePath
  where
    extractFrame :: FilePath -> Duration -> FilePath -> IO ()
    extractFrame sourcePath startAfter frameFileName =
      unlessM (doesFileExist frameFileName) $ do
        createDirectoryIfMissing True frameDir
        putStrLn
          ("Extracting frame at " <> printTimestamp startAfter <> " from " <>
           toS sourcePath <>
           ".")
        let allArgs =
              [ "-nostdin"
              , "-ss"
              , printf "%f" (durationToSeconds startAfter)
              , "-i"
              , sourcePath
              , "-vf"
              , "scale=" <> show (videoSettings ^. resolution . width) <> ":" <> show (videoSettings ^. resolution . height)
              , "-t"
              , "1"
              , "-vframes"
              , "1"
              , frameFileName
              ]
        printEscapedFFmpegInvocation (map toS allArgs)
        runFFmpeg $ proc "ffmpeg" allArgs
    runFFmpeg cmd = do
      (exit, _, err) <- readProcess cmd
      when
        (exit /= ExitSuccess)
        (Prelude.fail ("Couldn't extract frame from video file: " <> toS err))

runFFmpegRender :: (MonadIO m, Carrier sig m) => Eff (FFmpegRenderC m) a -> m a
runFFmpegRender = runFFmpegRenderC . interpret
