{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
module Komposition.Import.Audio.Sox (runSoxAudioImport) where

import           Komposition.Prelude        hiding (bracket, catch)
import qualified Prelude

import qualified Codec.FFmpeg.Probe         as Probe
import           Control.Effect
import           Control.Effect.Carrier
import           Control.Effect.Sum
import           Control.Monad.Catch        hiding (bracket)
import qualified Data.Char                  as Char
import qualified Data.Text                  as Text
import           Data.Time.Clock
import           Pipes
import           Pipes.Safe
import           System.Directory
import           System.FilePath
import qualified System.IO                  as IO
import           System.IO.Temp
import           System.Process.Typed

import           Komposition.Classification
import           Komposition.Duration
import           Komposition.FFmpeg.Command (Command (..))
import qualified Komposition.FFmpeg.Command as Command
import           Komposition.FFmpeg.Process (runFFmpegCommand)
import           Komposition.Import.Audio
import           Komposition.Library
import           Komposition.MediaType
import           Komposition.Progress

fromCarriageReturnOrNewlineSplit :: MonadIO m => Handle -> Producer Text m ()
fromCarriageReturnOrNewlineSplit h = go mempty
  where
    go buf = liftIO (IO.hIsEOF h) >>= \case
      True  -> yield buf
      False -> do
        c <- liftIO (IO.hGetChar h)
        if c `elem` ['\r', '\n']
          then yield buf >> go mempty
          else go (buf <> Text.singleton c)

runSoxWithProgress
  :: (MonadIO m, MonadSafe m)
  => (Double -> ProgressUpdate)
  -> [Prelude.String]
  -> Producer ProgressUpdate m ()
runSoxWithProgress toProgress args = do
  let process = proc "sox" ("-S" : args) & setStderr createPipe

  bracket (startProcess process) stopProcess $ \p -> do
    liftIO (IO.hSetBuffering (getStderr p) IO.NoBuffering)
    fromCarriageReturnOrNewlineSplit (getStderr p) >-> yieldProgress
    waitForExit p
  where
    yieldProgress :: MonadIO m => Pipe Text ProgressUpdate m ()
    yieldProgress = forever $ do
      line <- await
      case Text.splitOn ":" (Text.takeWhile (not . Char.isSpace) line) of
        ["In", percentStr] ->
          case readDouble (Text.init percentStr) of
            Just d  -> yield (toProgress (d / 100))
            Nothing -> return ()
        _ -> return ()
    waitForExit p = waitExitCode p >>= \case
      ExitSuccess   -> return ()
      ExitFailure e -> throwIO (ProcessFailed "sox" e Nothing)

normalizeAudio
  :: (MonadIO m, MonadSafe m)
  => FilePath -- Temporary directory to save normalized file in
  -> FilePath -- Source path
  -> Producer ProgressUpdate m FilePath -- Action with progress updates, returning the normalized file path
normalizeAudio tempDir sourcePath = do
  let toProgress = ProgressUpdate "Normalizing and gating audio"
      outPath = tempDir </> "preprocessed.wav"
  yield  (toProgress 0)
  runSoxWithProgress
    toProgress
    [ "--norm"
    , sourcePath
    , outPath
    , "compand"
    , ".1,.2"
    , "-inf,-50.1,-inf,-50,-50", "0"
    , "-90"
    , ".1"
    ]
  return outPath

splitAudioBySilence
  :: (MonadIO m, MonadSafe m)
  => FilePath
  -> FilePath
  -> FilePath
  -> Producer ProgressUpdate m [FilePath]
splitAudioBySilence outputDir fileNameTemplate sourcePath = do
  liftIO (createDirectoryIfMissing True outputDir)
  runSoxWithProgress
    (ProgressUpdate "Splitting by silence")
    [ sourcePath
    , outputDir </> fileNameTemplate
    , "silence"
    , "1", "0",   "0.05%"
    , "1", "0.5", "0.05%"
    , ":", "newfile"
    , ":", "restart"
    ]
  relFiles <- liftIO (System.Directory.listDirectory outputDir)
  return (map (outputDir </>) (sort relFiles))

dropSilentChunks
  :: (MonadIO m, MonadSafe m)
  => [FilePath]
  -> Producer ProgressUpdate m [FilePath]
dropSilentChunks fs =
  fold <$> zipWithM go [(1::Int)..] fs
  where
    count = length fs
    go n audioFilePath = do
      yield (ProgressUpdate "Dropping silent chunks" (fromIntegral n / fromIntegral count))
      lift (getAudioFileMaxAmplitude audioFilePath) >>= \case
        d | d > 0.05 -> return [audioFilePath]
          | otherwise -> liftIO (removeFile audioFilePath) >> return []

filePathToAudioAsset ::
     (MonadMask m, MonadIO m)
  => FilePath
  -> FilePath
  -> m (Asset 'Audio)
filePathToAudioAsset _outDir audioFilePath = do
  d <- getAudioFileDuration audioFilePath
  let meta = AssetMetadata (OriginalPath audioFilePath) d
  -- TODO: Generate waveform thumbnail
  return (AudioAsset meta)

getAudioFileDuration :: (MonadMask m, MonadIO m) => FilePath -> m Duration
getAudioFileDuration f =
  Duration . picosecondsToDiffTime . (* 1000000) . fromIntegral <$>
  Probe.withAvFile f Probe.duration

getAudioFileMaxAmplitude :: MonadIO m => FilePath -> m Double
getAudioFileMaxAmplitude inPath = do
  (ex, _, err) <- readProcess (proc "sox" [inPath, "-n", "stat"])
  case ex of
    ExitSuccess ->
      let parts = map (map Text.strip . Text.splitOn ":") (Text.lines (toS err))
      in maybe (throwIO (CouldNotReadMaximumAmplitude inPath)) return $ do
         (_ : ampStr : _) <- find ((==) (Just "Maximum amplitude") . headMay) parts
         readDouble ampStr
    ExitFailure c -> throwIO (ProcessFailed "sox" c (Just (toS err)))

transcodeAudioFileToWav
  :: (MonadIO m, MonadSafe m)
  => FilePath
  -> Duration
  -> FilePath
  -> Producer ProgressUpdate m FilePath
transcodeAudioFileToWav tempDir fullLength inPath = do
  -- TODO: use md5 digest to avoid collisions
  let outPath = tempDir </> takeBaseName inPath <> ".wav"
      cmd =
        Command
        { output = Command.FileOutput outPath
        , inputs = pure (Command.FileSource inPath)
        , filterGraph = Nothing
        , frameRate = Nothing
        , mappings = []
        , vcodec = Nothing
        , acodec = Nothing
        , format = Just "wav"
        }
  runFFmpegCommand (ProgressUpdate "Transcoding audio") fullLength cmd
  return outPath

newtype SoxAudioImportC m a = SoxAudioImportC { runSoxAudioImportC :: m a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance (MonadIO m, Carrier sig m) => Carrier (AudioImport :+: sig) (SoxAudioImportC m) where
  ret = pure
  eff = handleSum (SoxAudioImportC . eff . handleCoercible) $ \case
    ImportAudioFile classification srcFile outDir k ->
      case classification of
        Classified -> k $ do
          liftIO (createDirectoryIfMissing True outDir)
          bracket
            (do
              canonical <- liftIO getCanonicalTemporaryDirectory
              liftIO $ createTempDirectory canonical "komposition.audio.import")
            (liftIO . removeDirectoryRecursive)
            $ \tempDir -> do
              fullLength <- getAudioFileDuration srcFile
              -- TODO: use file md5 digest in filename (or for a subdirectory) to avoid collisions
              chunks <-
                divideProgress4
                  (transcodeAudioFileToWav tempDir fullLength srcFile)
                  (normalizeAudio tempDir)
                  (splitAudioBySilence (outDir </> "audio-chunks") (takeBaseName srcFile <> "-%5n.wav"))
                  dropSilentChunks
              lift (mapM (filePathToAudioAsset outDir) chunks)
        Unclassified -> k $ do
          Pipes.yield (ProgressUpdate "Importing Audio" 0)
          -- Copy asset to working directory
          assetPath <-
            liftIO $ do
              createDirectoryIfMissing True outDir
              let assetPath = outDir </> takeFileName srcFile
              copyFile srcFile assetPath
              return assetPath
          -- Generate thumbnail and return asset
          Pipes.yield (ProgressUpdate "Importing Audio" 0.5) *>
            (pure <$> filePathToAudioAsset outDir assetPath) <*
            Pipes.yield (ProgressUpdate "Importing Audio" 1)
    IsSupportedAudioFile p k ->
        -- TODO: Check that it can be processed, not just checking the extension
        k (takeExtension p `elem` [".wav", ".mp3", ".m4a", ".aiff", ".aac"])

runSoxAudioImport :: (MonadIO m, Carrier sig m) => Eff (SoxAudioImportC m) a -> m a
runSoxAudioImport = runSoxAudioImportC . interpret

data AudioImportError
  = UnexpectedError FilePath Text
  | ProcessFailed Text Int (Maybe Text)
  | CouldNotReadMaximumAmplitude FilePath
  | TranscodingFailed Text
  deriving (Show, Eq)

instance Exception AudioImportError
