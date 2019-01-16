{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE RecordWildCards #-}
module Komposition.UserInterface.GtkInterface.EventListener where

import           Komposition.Prelude

import           Control.Concurrent.Async       (race)
import qualified Data.HashMap.Strict            as HashMap
import qualified Data.HashSet                   as HashSet
import qualified GI.Gdk                         as Gdk
import qualified GI.GObject.Functions           as GObject
import qualified GI.Gtk                         as Gtk
import qualified GI.Gtk.Declarative.EventSource as Declarative
import qualified GI.Gtk.Declarative.State       as Declarative

import           Komposition.KeyMap

data EventListener e = EventListener
  { events      :: Chan e
  , unsubscribe :: IO ()
  }

readEvent :: EventListener e -> IO e
readEvent = readChan . events

subscribeToDeclarativeWidget
  :: Declarative.EventSource s => s e -> Declarative.SomeState -> IO (EventListener e)
subscribeToDeclarativeWidget declWidget st = do
  events       <- newChan
  subscription <- Declarative.subscribe declWidget st (writeChan events)
  pure EventListener { unsubscribe = Declarative.cancel subscription, .. }

raceEvent :: EventListener e -> EventListener e -> IO e
raceEvent a b =
  either pure pure =<< race (readEvent a) (readEvent b)

subscribeKeyEvents :: Gtk.Widget -> IO (EventListener KeyCombo)
subscribeKeyEvents w = do
  events <- newChan
  sid <-
    w `Gtk.onWidgetKeyPressEvent` \eventKey -> do
      keyVal <- Gdk.getEventKeyKeyval eventKey
      modifiers <- Gdk.getEventKeyState eventKey
      keyChar <- toEnum . fromIntegral <$> Gdk.keyvalToUnicode keyVal
      case toKeyCombo keyChar keyVal modifiers of
        Just keyCombo -> writeChan events keyCombo $> False
        _             -> return False
  return EventListener {unsubscribe = GObject.signalHandlerDisconnect w sid, ..}
  where
    toKey =
      \case
        (_, Gdk.KEY_Up) -> Just KeyUp
        (_, Gdk.KEY_Down) -> Just KeyDown
        (_, Gdk.KEY_Left) -> Just KeyLeft
        (_, Gdk.KEY_Right) -> Just KeyRight
        (_, Gdk.KEY_Escape) -> Just KeyEscape
        (_, Gdk.KEY_Return) -> Just KeyEnter
        (_, Gdk.KEY_space) -> Just KeySpace
        (c, _) -> Just (KeyChar c)
    toModifier = \case
      Gdk.ModifierTypeControlMask -> Just (KeyModifier Ctrl)
      Gdk.ModifierTypeMetaMask -> Just (KeyModifier Meta)
      _ -> Nothing
    toKeyCombo keyChar keyVal modifiers = do
      key <- toKey (keyChar :: Char, keyVal)
      pure (HashSet.fromList (key : mapMaybe toModifier modifiers))


applyKeyMap :: KeyMap a -> EventListener KeyCombo -> IO (EventListener a)
applyKeyMap topKeyMap keyPresses = do
  xs <- newChan
  let go (KeyMap km) = do
        combo <- readChan (events keyPresses)
        case HashMap.lookup combo km of
          Just (SequencedMappings km') -> go km'
          Just (Mapping           x  ) -> writeChan xs x >> go topKeyMap
          Nothing                      -> go topKeyMap
  tid <- forkIO (go topKeyMap)
  pure EventListener {events = xs, unsubscribe = killThread tid}
