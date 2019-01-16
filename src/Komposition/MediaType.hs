{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE GADTs          #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies   #-}
module Komposition.MediaType where

import           Komposition.Prelude

data MediaType = Video | Audio
  deriving (Eq, Show, Ord)

data SMediaType (mt :: MediaType) where
  SVideo :: SMediaType Video
  SAudio :: SMediaType Audio

type family InverseMediaType (t :: MediaType) :: MediaType where
  InverseMediaType Video = Audio
  InverseMediaType Audio = Video
