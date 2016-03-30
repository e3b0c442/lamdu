{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, DeriveFunctor, TemplateHaskell, NamedFieldPuns, DisambiguateRecordFields #-}
module Lamdu.GUI.CodeEdit
    ( make
    , Env(..)
    , M(..), m, mLiftTrans
    ) where

import           Control.Applicative (liftA2)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Trans.Class (lift)
import           Control.MonadA (MonadA)
import           Data.CurAndPrev (CurAndPrev(..))
import           Data.Functor.Identity (Identity(..))
import           Data.List (intersperse)
import           Data.List.Utils (insertAt, removeAt)
import           Data.Orphans () -- Imported for Monoid (IO ()) instance
import qualified Data.Store.IRef as IRef
import           Data.Store.Property (Property(..))
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Graphics.UI.Bottle.EventMap as E
import           Graphics.UI.Bottle.ModKey (ModKey(..))
import           Graphics.UI.Bottle.Widget (Widget)
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets as BWidgets
import qualified Graphics.UI.Bottle.Widgets.Box as Box
import qualified Graphics.UI.Bottle.Widgets.Spacer as Spacer
import           Graphics.UI.Bottle.WidgetsEnvT (WidgetEnvT)
import qualified Graphics.UI.Bottle.WidgetsEnvT as WE
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Eval.Results (EvalResults)
import           Lamdu.Expr.IRef (DefI, ValI)
import qualified Lamdu.Expr.Load as Load
import           Lamdu.GUI.CodeEdit.Settings (Settings)
import qualified Lamdu.GUI.DefinitionEdit as DefinitionEdit
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.RedundantAnnotations as RedundantAnnotations
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Style (Style)
import qualified Lamdu.Sugar.Convert as SugarConvert
import qualified Lamdu.Sugar.Names.Add as AddNames
import           Lamdu.Sugar.Names.Types (DefinitionN)
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.OrderTags as OrderTags
import qualified Lamdu.Sugar.PresentationModes as PresentationModes
import qualified Lamdu.Sugar.Types as Sugar

import           Prelude.Compat

type T = Transaction

newtype M m a = M { _m :: IO (T m (IO (), a)) }
    deriving (Functor)
Lens.makeLenses ''M

instance Monad m => Applicative (M m) where
    pure = M . pure . pure . pure
    M f <*> M x = (liftA2 . liftA2 . liftA2) ($) f x & M

mLiftTrans :: Functor m => T m a -> M m a
mLiftTrans = M . pure . fmap pure

mLiftWidget :: Functor m => Widget (T m) -> Widget (M m)
mLiftWidget = Widget.events %~ mLiftTrans

data Pane m = Pane
    { paneDefI :: DefI m
    , paneDel :: Maybe (T m Widget.Id)
    , paneMoveDown :: Maybe (T m ())
    , paneMoveUp :: Maybe (T m ())
    }

data Env m = Env
    { codeProps :: Anchors.CodeProps m
    , exportRepl :: M m ()
    , importAll :: FilePath -> M m ()
    , evalResults :: CurAndPrev (EvalResults (ValI m))
    , config :: Config
    , settings :: Settings
    , style :: Style
    }

makePanes :: MonadA m => Widget.Id -> Transaction.Property m [DefI m] -> [Pane m]
makePanes defaultDelDest (Property panes setPanes) =
    panes ^@.. Lens.traversed <&> convertPane
    where
        mkMDelPane i
            | not (null panes) =
                Just $ do
                    let newPanes = removeAt i panes
                    setPanes newPanes
                    newPanes ^? Lens.ix i
                        & maybe defaultDelDest (WidgetIds.fromGuid . IRef.guid)
                        & return
            | otherwise = Nothing
        movePane oldIndex newIndex =
            insertAt newIndex item (before ++ after)
            & setPanes
            where
                (before, item:after) = splitAt oldIndex panes
        mkMMovePaneDown i
            | i+1 < length panes = Just $ movePane i (i+1)
            | otherwise = Nothing
        mkMMovePaneUp i
            | i-1 >= 0 = Just $ movePane i (i-1)
            | otherwise = Nothing
        convertPane (i, defI) = Pane
            { paneDefI = defI
            , paneDel = mkMDelPane i
            , paneMoveDown = mkMMovePaneDown i
            , paneMoveUp = mkMMovePaneUp i
            }

toExprGuiMPayload :: ([Sugar.EntityId], NearestHoles) -> ExprGuiT.Payload
toExprGuiMPayload (entityIds, nearestHoles) =
    ExprGuiT.emptyPayload nearestHoles & ExprGuiT.plStoredEntityIds .~ entityIds

postProcessExpr ::
    MonadA m =>
    Sugar.Expression name m [Sugar.EntityId] ->
    Sugar.Expression name m ExprGuiT.Payload
postProcessExpr expr =
    expr
    <&> (,)
    & runIdentity . NearestHoles.add traverse . Identity
    <&> toExprGuiMPayload
    & RedundantAnnotations.markAnnotationsToDisplay

processPane ::
    MonadA m => Env m -> Pane m ->
    T m (Pane m, DefinitionN m ExprGuiT.Payload)
processPane env pane =
    paneDefI pane
    & Load.def
    >>= SugarConvert.convertDefI (evalResults env) (codeProps env)
    >>= OrderTags.orderDef
    >>= PresentationModes.addToDef
    >>= AddNames.addToDef
    <&> fmap postProcessExpr
    <&> (,) pane

processExpr ::
    MonadA m => Env m -> Transaction.Property m (ValI m) ->
    T m (ExprGuiT.SugarExpr m)
processExpr env expr =
    Load.exprProperty expr
    >>= SugarConvert.convertExpr (evalResults env) (codeProps env)
    >>= OrderTags.orderExpr
    >>= PresentationModes.addToExpr
    >>= AddNames.addToExpr
    <&> postProcessExpr

gui ::
    MonadA m =>
    Env m -> Widget.Id -> ExprGuiT.SugarExpr m -> [Pane m] ->
    WidgetEnvT (T m) (Widget (M m))
gui env rootId replExpr panes =
    do
        replEdit <- makeReplEdit env rootId replExpr
        panesEdits <-
            panes
            & ExprGuiM.transaction . traverse (processPane env)
            >>= traverse (makePaneEdit env (Config.pane (config env)))
            <&> fmap mLiftWidget
        newDefinitionButton <- makeNewDefinitionButton rootId <&> mLiftWidget
        eventMap <- panesEventMap env & ExprGuiM.widgetEnv
        [replEdit] ++ panesEdits ++ [newDefinitionButton]
            & intersperse space
            & Box.vboxAlign 0
            & Widget.weakerEvents eventMap
            & return
    & ExprGuiM.assignCursor rootId replId
    & ExprGuiM.run ExpressionEdit.make
      (codeProps env) (config env) (settings env) (style env)
    where
        space = Spacer.makeWidget 50
        replId = replExpr ^. Sugar.rPayload . Sugar.plEntityId & WidgetIds.fromEntityId

make :: MonadA m => Env m -> Widget.Id -> WidgetEnvT (T m) (Widget (M m))
make env rootId =
    do
        replExpr <-
            getProp Anchors.repl >>= lift . processExpr env
        panes <- getProp Anchors.panes <&> makePanes rootId
        gui env rootId replExpr panes
    where
        getProp f = f (codeProps env) ^. Transaction.mkProperty & lift

makePaneEdit ::
    MonadA m =>
    Env m -> Config.Pane -> (Pane m, DefinitionN m ExprGuiT.Payload) ->
    ExprGuiM m (Widget (T m))
makePaneEdit env paneConfig (pane, defS) =
    makePaneWidget (config env) defS
    <&> Widget.weakerEvents paneEventMap
    where
        Config.Pane{paneCloseKeys, paneMoveDownKeys, paneMoveUpKeys} = paneConfig
        paneEventMap =
            [ maybe mempty
                (Widget.keysEventMapMovesCursor paneCloseKeys
                  (E.Doc ["View", "Pane", "Close"])) $ paneDel pane
            , maybe mempty
                (Widget.keysEventMap paneMoveDownKeys
                  (E.Doc ["View", "Pane", "Move down"])) $ paneMoveDown pane
            , maybe mempty
                (Widget.keysEventMap paneMoveUpKeys
                  (E.Doc ["View", "Pane", "Move up"])) $ paneMoveUp pane
            ] & mconcat

makeNewDefinitionEventMap ::
    MonadA m => Anchors.CodeProps m ->
    WidgetEnvT (T m) ([ModKey] -> Widget.EventHandlers (T m))
makeNewDefinitionEventMap cp =
    do
        curCursor <- WE.readCursor
        let newDefinition =
                do
                    newDefI <-
                        DataOps.newHole >>= DataOps.newPublicDefinitionWithPane "" cp
                    DataOps.savePreJumpPosition cp curCursor
                    return newDefI
                <&> WidgetIds.nameEditOf . WidgetIds.fromIRef
        return $ \newDefinitionKeys ->
            Widget.keysEventMapMovesCursor newDefinitionKeys
            (E.Doc ["Edit", "New definition"]) newDefinition

makeNewDefinitionButton :: MonadA m => Widget.Id -> ExprGuiM m (Widget (T m))
makeNewDefinitionButton myId =
    do
        codeAnchors <- ExprGuiM.readCodeAnchors
        newDefinitionEventMap <-
            makeNewDefinitionEventMap codeAnchors & ExprGuiM.widgetEnv

        Config.Pane{newDefinitionActionColor, newDefinitionButtonPressKeys} <-
            ExprGuiM.readConfig <&> Config.pane

        BWidgets.makeFocusableTextView "New..." newDefinitionButtonId
            & WE.localEnv (WE.setTextColor newDefinitionActionColor)
            & ExprGuiM.widgetEnv
            <&> Widget.weakerEvents
                (newDefinitionEventMap newDefinitionButtonPressKeys)
    where
        newDefinitionButtonId = Widget.joinId myId ["NewDefinition"]

makeReplEventMap ::
    MonadA m => Env m -> Sugar.Expression name m a -> Config ->
    Widget.EventHandlers (M m)
makeReplEventMap env replExpr config =
    mconcat
    [ Widget.keysEventMapMovesCursor newDefinitionButtonPressKeys
      (E.Doc ["Edit", "Extract to definition"]) extractAction
    , Widget.keysEventMap exportKeys
      (E.Doc ["Collaboration", "Export repl to JSON file"]) exportAction
    ]
    where
        Config.Export{exportKeys} = Config.export config
        Config.Pane{newDefinitionButtonPressKeys} = Config.pane config
        exportAction = exportRepl env
        extractAction =
            replExpr ^. Sugar.rPayload . Sugar.plActions . Sugar.extract
            <&> ExprEventMap.extractCursor
            & mLiftTrans

makeReplEdit ::
    MonadA m => Env m -> Widget.Id -> ExprGuiT.SugarExpr m -> ExprGuiM m (Widget (M m))
makeReplEdit env myId replExpr =
    do
        replLabel <-
            ExpressionGui.makeLabel "⋙" (Widget.toAnimId replId)
            >>= ExpressionGui.makeFocusableView replId
        expr <- ExprGuiM.makeSubexpression id replExpr
        replEventMap <-
            ExprGuiM.readConfig <&> makeReplEventMap env replExpr
        ExpressionGui.hboxSpaced [replLabel, expr]
            <&> (^. ExpressionGui.egWidget)
            <&> mLiftWidget
            <&> Widget.weakerEvents replEventMap
    where
        replId = Widget.joinId myId ["repl"]

panesEventMap ::
    MonadA m => Env m -> WidgetEnvT (T m) (Widget.EventHandlers (M m))
panesEventMap Env{config,codeProps,importAll} =
    do
        mJumpBack <- DataOps.jumpBack codeProps & lift <&> fmap mLiftTrans
        newDefinitionEventMap <- makeNewDefinitionEventMap codeProps
        return $ mconcat
            [ newDefinitionEventMap (Config.newDefinitionKeys (Config.pane config))
              <&> mLiftTrans
            , E.dropEventMap "Drag&drop 1 JSON file"
              (E.Doc ["Collaboration", "Import JSON file"]) importAction
              <&> fmap (\() -> mempty)
            , maybe mempty
              (Widget.keysEventMapMovesCursor (Config.previousCursorKeys config)
               (E.Doc ["Navigation", "Go back"])) mJumpBack
            ]
    where
        importAction [filePath] = Just (importAll filePath)
        importAction _ = Nothing

makePaneWidget ::
    MonadA m => Config -> DefinitionN m ExprGuiT.Payload -> ExprGuiM m (Widget (T m))
makePaneWidget conf defS =
    DefinitionEdit.make defS <&> colorize
    where
        Config.Pane{paneActiveBGColor,paneInactiveTintColor} = Config.pane conf
        colorize widget
            | widget ^. Widget.isFocused = colorizeActivePane widget
            | otherwise = colorizeInactivePane widget
        colorizeActivePane =
            Widget.backgroundColor
            (Config.layerActivePane (Config.layers conf))
            WidgetIds.activePaneBackground paneActiveBGColor
        colorizeInactivePane = Widget.tint paneInactiveTintColor
