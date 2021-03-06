{-# LANGUAGE TemplateHaskell, MultiParamTypeClasses, FlexibleInstances #-}
module Test.Momentu.Env where

import qualified Control.Lens as Lens
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.I18N as MomentuTexts
import qualified GUI.Momentu.Widgets.Grid as Grid

import           Test.Lamdu.Prelude

data Env = Env
    { _eDirLayout :: Dir.Layout
    , _eDirTexts :: Dir.Texts Text
    , _eGlueTexts :: Glue.Texts Text
    , _eGridTexts :: Grid.Texts Text
    , _eMomentuTexts :: MomentuTexts.Texts Text
    }

env :: Env
env =
    Env
    { _eDirLayout = Dir.LeftToRight -- TODO: Test other layout directions
    , _eDirTexts =
        Dir.Texts
        { Dir._left = "left"
        , Dir._right = "right"
        , Dir._up = "up"
        , Dir._down = "down"
        }
    , _eGlueTexts =
        Glue.Texts
        { Glue._stroll = "stroll"
        , Glue._back = "back"
        , Glue._ahead = "ahead"
        }
    , _eGridTexts =
        Grid.Texts
        { Grid._moreLeft = "more left"
        , Grid._moreRight = "more right"
        , Grid._top = "top"
        , Grid._bottom = "bottom"
        , Grid._leftMost = "left-most"
        , Grid._rightMost = "right-most"
        }
    , _eMomentuTexts =
        MomentuTexts.Texts
        { MomentuTexts._edit = "Edit"
        , MomentuTexts._view = "View"
        , MomentuTexts._insert = "Insert"
        , MomentuTexts._delete = "Delete"
        , MomentuTexts._navigation = "navigation"
        , MomentuTexts._move = "move"
        }
    }

Lens.makeLenses ''Env

instance Has Dir.Layout Env where has = eDirLayout
instance Has (Dir.Texts Text) Env where has = eDirTexts
instance Has (Glue.Texts Text) Env where has = eGlueTexts
instance Has (Grid.Texts Text) Env where has = eGridTexts
instance Has (MomentuTexts.Texts Text) Env where has = eMomentuTexts
