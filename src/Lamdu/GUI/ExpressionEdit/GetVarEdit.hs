module Lamdu.GUI.ExpressionEdit.GetVarEdit
    ( make, makeGetBinder, makeNoActions, makeSimpleView, addInfixMarker
    , Role(..)
    ) where

import qualified Control.Lens as Lens
import qualified Control.Monad.Reader as Reader
import qualified Data.ByteString.Char8 as SBS8
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (TextWidget)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.Direction as Dir
import qualified GUI.Momentu.Draw as Draw
import           GUI.Momentu.Element (Element)
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Font (Underline(..))
import           GUI.Momentu.Glue ((/|/))
import qualified GUI.Momentu.Glue as Glue
import qualified GUI.Momentu.I18N as MomentuTexts
import qualified GUI.Momentu.Hover as Hover
import           GUI.Momentu.MetaKey (MetaKey(..), noMods)
import qualified GUI.Momentu.MetaKey as MetaKey
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.Responsive.Options as Options
import           GUI.Momentu.State (Gui)
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Grid as Grid
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified GUI.Momentu.Widgets.TextView as TextView
import qualified Lamdu.CharClassification as Chars
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import           Lamdu.Config.Theme (Theme)
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.Config.Theme.TextColors (TextColors)
import qualified Lamdu.Config.Theme.TextColors as TextColors
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import           Lamdu.GUI.ExpressionGui.Wrap (stdWrap)
import qualified Lamdu.GUI.LightLambda as LightLambda
import qualified Lamdu.GUI.NameView as NameView
import           Lamdu.GUI.Styled (grammar, label)
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Code as Texts
import qualified Lamdu.I18N.CodeUI as Texts
import qualified Lamdu.I18N.Definitions as Texts
import qualified Lamdu.I18N.Navigation as Texts
import qualified Lamdu.I18N.Name as Texts
import           Lamdu.Name (Name(..))
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

makeSimpleView ::
    ( MonadReader env m, GuiState.HasCursor env, Has Theme env
    , Applicative f, Element.HasAnimIdPrefix env, Has TextView.Style env
    , Has Dir.Layout env, Has (Texts.Name Text) env
    ) =>
    Lens.ALens' TextColors Draw.Color -> Name x -> Widget.Id ->
    m (TextWidget f)
makeSimpleView color name myId =
    (Widget.makeFocusableView ?? myId <&> (Align.tValue %~))
    <*> NameView.make name
    & Styled.withColor (Lens.cloneLens color)

makeParamsRecord ::
    ( MonadReader env m, Has Theme env, GuiState.HasCursor env
    , Element.HasAnimIdPrefix env, Spacer.HasStdSpacing env
    , Glue.HasTexts env, Has (Texts.Code Text) env, Has (Texts.Name Text) env
    , Applicative f
    ) =>
    Widget.Id -> Sugar.ParamsRecordVarRef (Name f) -> m (Gui Responsive f)
makeParamsRecord myId paramsRecordVar =
    do
        respondToCursor <- Widget.respondToCursorPrefix ?? myId
        (Options.box ?? Options.disambiguationNone)
            <*> sequence
            [ grammar (label Texts.paramsRecordOpener) <&> Responsive.fromTextView
            , (Options.boxSpaced ?? Options.disambiguationNone)
              <*>
              ( fieldNames
                & Lens.itraverse
                (\i fieldName ->
                    let paramId = ["params", SBS8.pack (show (i :: Int))]
                    in
                    Widget.joinId myId paramId
                    & makeSimpleView TextColors.parameterColor fieldName
                    <&> Responsive.fromWithTextPos
                    & Reader.local (Element.animIdPrefix %~ (<> paramId))
                )
              )
            , grammar (label Texts.paramsRecordCloser) <&> Responsive.fromTextView
            ] <&> respondToCursor
    where
        Sugar.ParamsRecordVarRef fieldNames = paramsRecordVar

infixMarker :: Vector2 Anim.R -> Draw.Image
infixMarker (Vector2 w h) =
    () <$
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
    where
        x = min w h / 4

addInfixMarker :: Element a => Widget.Id -> a -> a
addInfixMarker widgetId =
    Element.bottomLayer %@~
    \size -> Anim.singletonFrame 1 frameId (infixMarker size) & flip mappend
    where
        frameId = Widget.toAnimId widgetId ++ ["infix"]

data Role = Normal | Infix deriving Eq

navDoc ::
    ( Has (Texts.Navigation Text) env
    , Has (MomentuTexts.Texts Text) env
    ) =>
    env -> Lens.ALens' (Texts.Navigation Text) Text -> E.Doc
navDoc env lens =
    E.toDoc env [has . MomentuTexts.navigation, has . lens]

makeNameRef ::
    (Monad i, Monad o) =>
    Role ->
    Lens.ALens' TextColors Draw.Color -> Widget.Id ->
    Sugar.NameRef (Name x) o ->
    ExprGuiM env i o (TextWidget o)
makeNameRef role color myId nameRef =
    do
        savePrecursor <- ExprGuiM.mkPrejumpPosSaver
        env <- Lens.view id
        let jumpToDefinitionEventMap =
                E.keysEventMapMovesCursor
                (env ^. has . Config.jumpToDefinitionKeys ++
                 env ^. has . Config.extractKeys)
                (navDoc env Texts.jumpToDef) $
                do
                    savePrecursor
                    nameRef ^. Sugar.nrGotoDefinition <&> WidgetIds.fromEntityId
        nameText <- Name.visible name <&> (^. _1 . Name.ttText)
        let mAddMarker
                | (role == Infix) == Lens.allOf Lens.each (`elem` Chars.operator) nameText = id
                | otherwise = addInfixMarker nameId
        makeSimpleView color name nameId
            <&> mAddMarker
            <&> Align.tValue %~ Widget.weakerEvents jumpToDefinitionEventMap
    & Reader.local (Element.animIdPrefix .~ Widget.toAnimId nameId)
    & GuiState.assignCursor myId nameId
    where
        name = nameRef ^. Sugar.nrName
        nameId = Widget.joinId myId ["name"]

makeInlineEventMap ::
    ( Has Config env, Has (MomentuTexts.Texts Text) env
    , Has (Texts.CodeUI Text) env
    , Has (Texts.Navigation Text) env
    , Applicative f
    ) =>
    env -> Sugar.BinderVarInline f ->
    Gui EventMap f
makeInlineEventMap env (Sugar.InlineVar inline) =
    inline <&> WidgetIds.fromEntityId
    & E.keysEventMapMovesCursor (env ^. has . Config.inlineKeys)
      (E.toDoc env [has . MomentuTexts.edit, has . Texts.inline])
makeInlineEventMap env (Sugar.CannotInlineDueToUses (x:_)) =
    WidgetIds.fromEntityId x & pure
    & E.keysEventMapMovesCursor (env ^. has . Config.inlineKeys)
      (navDoc env Texts.jumpToNextUse)
makeInlineEventMap _ _ = mempty

definitionTypeChangeBox ::
    ( MonadReader env m, Glue.HasTexts env, Has (Texts.Code Text) env
    , Element.HasAnimIdPrefix env, Has (Texts.Definitions Text) env
    , Spacer.HasStdSpacing env, Has Theme env, GuiState.HasCursor env
    , Has Config env
    , Has (Texts.Name Text) env, Grid.HasTexts env
    , Applicative f
    ) =>
    Sugar.DefinitionOutdatedType (Name x) (f Sugar.EntityId) -> Widget.Id ->
    m (TextWidget f)
definitionTypeChangeBox info getVarId =
    do
        env <- Lens.view id
        let updateDoc =
                E.toDoc env
                [has . MomentuTexts.edit, has . Texts.updateDefType]
        oldTypeRow <- Styled.info (label Texts.defUpdateWas)
        newTypeRow <-
            Styled.actionable myId Texts.defUpdateHeader
            updateDoc update
            /|/ Spacer.stdHSpace
            /|/ Styled.info (label Texts.defUpdateTo)

        oldTypeView <- mkTypeView "oldTypeView" (info ^. Sugar.defTypeWhenUsed)
        newTypeView <- mkTypeView "newTypeView" (info ^. Sugar.defTypeCurrent)

        Grid.make ??
            [ [ Align.fromWithTextPos 0 (oldTypeRow <&> Widget.fromView)
              , Align.fromWithTextPos 0 (oldTypeView <&> Widget.fromView) ]
            , [ Align.fromWithTextPos 0 newTypeRow
              , Align.fromWithTextPos 0 (newTypeView <&> Widget.fromView) ]
            ] <&> snd <&> Align.WithTextPos 0
    where
        update = info ^. Sugar.defTypeUseCurrent <&> WidgetIds.fromEntityId
        mkTypeView idSuffix scheme =
            TypeView.makeScheme scheme
            & Reader.local (Element.animIdPrefix .~ animId ++ [idSuffix])
        myId = Widget.joinId getVarId ["type change"]
        animId = Widget.toAnimId myId

processDefinitionWidget ::
    ( MonadReader env m, Spacer.HasStdSpacing env
    , Has Theme env, Element.HasAnimIdPrefix env, Has Config env
    , GuiState.HasCursor env, Has Hover.Style env, Has (Texts.Definitions Text) env
    , Has (Texts.Code Text) env, Has (Texts.CodeUI Text) env, Glue.HasTexts env
    , Has (Texts.Name Text) env, Grid.HasTexts env
    , Applicative f
    ) =>
    Sugar.DefinitionForm (Name x) f -> Widget.Id ->
    m (TextWidget f) ->
    m (TextWidget f)
processDefinitionWidget Sugar.DefUpToDate _myId mkLayout = mkLayout
processDefinitionWidget Sugar.DefDeleted _myId mkLayout =
    Styled.deletedUse <*> mkLayout
processDefinitionWidget (Sugar.DefTypeChanged info) myId mkLayout =
    do
        env <- Lens.view id
        let showDialogEventMap =
                pure myId
                & E.keysEventMapMovesCursor [MetaKey noMods MetaKey.Key'Enter]
                (E.toDoc env
                    [ has . MomentuTexts.view
                    , has . Texts.typeUpdateDialog
                    , has . Texts.show
                    ])
        let hideDialogEventMap =
                pure hiddenId
                & E.keysEventMapMovesCursor [MetaKey noMods MetaKey.Key'Escape]
                (E.toDoc env
                    [ has . MomentuTexts.view
                    , has . Texts.typeUpdateDialog
                    , has . Texts.hide
                    ])
        let underline = Underline
                { _underlineColor = env ^. has . Theme.errorColor
                , _underlineWidth = env ^. has . Theme.wideUnderlineWidth
                }
        layout <-
            Reader.local (TextView.underline ?~ underline) mkLayout
            & GuiState.assignCursor hiddenId myId
        isSelected <- GuiState.isSubCursor ?? myId
        isHidden <- GuiState.isSubCursor ?? hiddenId
        case (isHidden, isSelected) of
            (True, _) ->
                layout
                <&> Widget.strongerEventsWithoutPreevents showDialogEventMap
                & pure
            (False, True) ->
                ( Hover.hoverBeside Align.tValue ?? layout )
                <*>
                ( definitionTypeChangeBox info myId <&> (^. Align.tValue) )
                <&> fmap (Widget.weakerEventsWithoutPreevents hideDialogEventMap)
            (False, False) -> pure layout
    where
        hiddenId = myId `Widget.joinId` ["hidden"]

makeGetBinder ::
    (Monad i, Monad o) =>
    Role -> Sugar.BinderVarRef (Name x) o -> Widget.Id ->
    ExprGuiM env i o (TextWidget o)
makeGetBinder role binderVar myId =
    do
        env <- Lens.view id
        let (color, processDef) =
                case binderVar ^. Sugar.bvForm of
                Sugar.GetLet -> (TextColors.letColor, id)
                Sugar.GetDefinition defForm ->
                    ( TextColors.definitionColor
                    , processDefinitionWidget defForm myId
                    )
        makeNameRef role color myId (binderVar ^. Sugar.bvNameRef)
            <&> Align.tValue %~ Widget.weakerEvents
                (makeInlineEventMap env (binderVar ^. Sugar.bvInline))
            & processDef

makeGetParam ::
    (Monad i, Monad o) =>
    Sugar.ParamRef (Name x) o -> Widget.Id ->
    ExprGuiM env i o (TextWidget o)
makeGetParam param myId =
    do
        underline <- Lens.view has <&> LightLambda.underline
        let mk = makeNameRef Normal TextColors.parameterColor myId (param ^. Sugar.pNameRef)
        case param ^. Sugar.pBinderMode of
            Sugar.LightLambda ->
                mk
                & Reader.local (TextView.underline ?~ underline)
                & Styled.nameAtBinder name
            Sugar.NormalBinder -> mk
    where
        name = param ^. Sugar.pNameRef . Sugar.nrName

makeNoActions ::
    (Monad i, Monad o) =>
    Sugar.GetVar (Name o) o ->
    Widget.Id ->
    ExprGuiM env i o (Gui Responsive o)
makeNoActions getVar myId =
    case getVar of
    Sugar.GetBinder binderVar ->
        makeGetBinder Normal binderVar myId <&> Responsive.fromWithTextPos
    Sugar.GetParamsRecord paramsRecordVar ->
        makeParamsRecord myId paramsRecordVar
    Sugar.GetParam param ->
        makeGetParam param myId <&> Responsive.fromWithTextPos

make ::
    (Monad i, Monad o) =>
    Sugar.GetVar (Name o) o ->
    Sugar.Payload (Name o) i o ExprGui.Payload ->
    ExprGuiM env i o (Gui Responsive o)
make getVar pl =
    stdWrap pl <*> makeNoActions getVar (WidgetIds.fromExprPayload pl)
