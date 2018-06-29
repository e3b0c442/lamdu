{-# LANGUAGE DisambiguateRecordFields #-}
module Lamdu.GUI.ExpressionEdit.ApplyEdit
    ( makeSimple, makeLabeled
    ) where

import qualified Control.Lens as Lens
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Animation (AnimId)
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.Draw as Draw
import           GUI.Momentu.Element (Element)
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Expression as ResponsiveExpr
import qualified GUI.Momentu.Responsive.Options as Options
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.CharClassification as Chars
import qualified Lamdu.GUI.ExpressionEdit.GetVarEdit as GetVarEdit
import qualified Lamdu.GUI.ExpressionEdit.TagEdit as TagEdit
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.ExpressionGui.Wrap (stdWrap, stdWrapParentExpr)
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

infixMarker :: Vector2 Anim.R -> Draw.Image
infixMarker (Vector2 w h) =
    mconcat
    [ Draw.line (x, 0) (0,x)
    , Draw.line (w-x, 0) (w,x)
    , Draw.line (w-x, h) (w,h-x)
    , Draw.line (x, h) (0,h-x)
    , Draw.line (0, x) (0, h-x)
    , Draw.line (w, x) (w, h-x)
    , Draw.line (x, 0) (w-x, 0)
    , Draw.line (x, h) (w-x, h)
    ]
    <&> const ()
    where
        x = min w h / 4

addInfixMarker :: Element a => Widget.Id -> a -> a
addInfixMarker widgetId =
    Element.bottomLayer %@~
    \size -> Anim.singletonFrame 1 frameId (infixMarker size) & flip mappend
    where
        frameId = Widget.toAnimId widgetId ++ ["infix"]

makeFunc ::
    (Monad i, Monad o) =>
    Sugar.LabeledApplyFunc (Name o) o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (ExpressionGui o)
makeFunc func =
    stdWrap pl <*>
    ( GetVarEdit.makeGetBinder (func ^. Sugar.fVar) myId
        <&> Responsive.fromWithTextPos
    )
    where
        pl = func ^. Sugar.fPayload
        myId = WidgetIds.fromExprPayload pl

makeInfixFunc ::
    (Monad i, Monad o) =>
    Sugar.LabeledApplyFunc (Name o) o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (ExpressionGui o)
makeInfixFunc func =
    makeFunc func <&> mAddMarker
    where
        nameText =
            Name.visible (func ^. Sugar.fVar . Sugar.bvNameRef . Sugar.nrName)
            ^. _1 . Name.ttText
        mAddMarker
            | Lens.allOf Lens.each (`elem` Chars.operator) nameText = id
            | otherwise = addInfixMarker myId
        myId = func ^. Sugar.fPayload & WidgetIds.fromExprPayload

isBoxed :: Sugar.LabeledApply name i o a -> Bool
isBoxed apply =
    Lens.has (Sugar.aAnnotatedArgs . traverse) apply
    || Lens.has (Sugar.aRelayedArgs . traverse) apply

makeFuncRow ::
    (Monad i, Monad o) =>
    Maybe AnimId ->
    Sugar.LabeledApply (Name o) i o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExprGuiM i o (ExpressionGui o)
makeFuncRow mParensId apply =
    case apply ^. Sugar.aSpecialArgs of
    Sugar.Verbose -> makeFunc func
    Sugar.Object arg ->
        (ResponsiveExpr.boxSpacedMDisamb ?? mParensId)
        <*> sequenceA
        [ makeFunc func
        , ExprGuiM.makeSubexpression arg
        ]
    Sugar.Infix l r ->
        (ResponsiveExpr.boxSpacedMDisamb ?? mParensId)
        <*> sequenceA
        [ (Options.boxSpaced ?? Options.disambiguationNone)
            <*> sequenceA
            [ ExprGuiM.makeSubexpression l
            , makeInfixFunc func
            ]
        , ExprGuiM.makeSubexpression r
        ]
    where
        func = apply ^. Sugar.aFunc

makeLabeled ::
    (Monad i, Monad o) =>
    Sugar.LabeledApply (Name o) i o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (ExpressionGui o)
makeLabeled apply pl =
    stdWrapParentExpr pl
    <*> (makeFuncRow (ExprGui.mParensId pl) apply >>= addBox)
    where
        addBox
            | isBoxed apply = mkBoxed apply
            | otherwise = pure

makeArgRow ::
    (Monad i, Monad o) =>
    Sugar.AnnotatedArg (Name o) (ExprGui.SugarExpr i o) ->
    ExprGuiM i o (Responsive.TaggedItem (o GuiState.Update))
makeArgRow arg =
    do
        argTag <- TagEdit.makeArgTag (arg ^. Sugar.aaTag . Sugar.tagName) (arg ^. Sugar.aaTag . Sugar.tagInstance)
        space <- Spacer.stdHSpace
        expr <- ExprGuiM.makeSubexpression (arg ^. Sugar.aaExpr)
        pure Responsive.TaggedItem
            { Responsive._tagPre = argTag /|/ space <&> Widget.fromView
            , Responsive._taggedItem = expr
            , Responsive._tagPost = Element.empty
            }

mkRelayedArgs ::
    (Monad i, Monad o) =>
    [Sugar.RelayedArg (Name o) o (Sugar.Payload (Name o) i o ExprGui.Payload)] ->
    ExprGuiM i o (ExpressionGui o)
mkRelayedArgs args =
    do
        argEdits <- traverse makeArgEdit args
        collapsed <- Styled.grammarLabel "➾" <&> Responsive.fromTextView
        Options.boxSpaced ?? Options.disambiguationNone ?? collapsed : argEdits
    where
        makeArgEdit arg = GetVarEdit.make (arg ^. Sugar.raValue) (arg ^. Sugar.raPayload)

mkBoxed ::
    (Monad i, Monad o) =>
    Sugar.LabeledApply (Name o) i o (Sugar.Payload (Name o) i o ExprGui.Payload) ->
    ExpressionGui o ->
    ExprGuiM i o (ExpressionGui o)
mkBoxed apply funcRow =
    do
        argRows <-
            case apply ^. Sugar.aAnnotatedArgs of
            [] -> pure []
            xs ->
                Responsive.taggedList
                <*> traverse makeArgRow xs
                <&> (:[])
        relayedArgs <-
            case apply ^. Sugar.aRelayedArgs of
            [] -> pure []
            args -> mkRelayedArgs args <&> (:[])
        Styled.addValFrame
            <*> (Responsive.vboxSpaced ?? (funcRow : argRows ++ relayedArgs))

makeSimple ::
    (Monad i, Monad o) =>
    Sugar.Apply (ExprGui.SugarExpr i o) ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM i o (ExpressionGui o)
makeSimple (Sugar.Apply func arg) pl =
    stdWrapParentExpr pl
    <*> ( (ResponsiveExpr.boxSpacedMDisamb ?? ExprGui.mParensId pl)
            <*> sequenceA
            [ ExprGuiM.makeSubexpression func
            , ExprGuiM.makeSubexpression arg
            ]
        )
