{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

module Tests.Gui where

import           AST (Tree)
import           AST.Knot.Ann (Ann(..), ann, val)
import qualified Control.Lens.Extended as Lens
import           Control.Monad.Unit (Unit(..))
import           Data.Functor.Identity (Identity(..))
import qualified Data.Map as Map
import           Data.Vector.Vector2 (Vector2(..))
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (Event(..))
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.MetaKey (MetaKey(..), noMods)
import           GUI.Momentu.Rect (Rect(..))
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import           GUI.Momentu.State (Gui, HasCursor(..), VirtualCursor(..))
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified Graphics.UI.GLFW as GLFW
import           Lamdu.Data.Db.Layout (ViewM)
import qualified Lamdu.Data.Db.Layout as DbLayout
import qualified Lamdu.GUI.DefinitionEdit as DefinitionEdit
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import qualified Lamdu.GUI.ExpressionEdit.BinderEdit as BinderEdit
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds as HoleWidgetIds
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Payload as ExprGui
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Types as Sugar
import           Revision.Deltum.Transaction (Transaction)
import qualified Revision.Deltum.Transaction as Transaction
import           System.Directory (listDirectory)
import qualified Test.Lamdu.Env as Env
import           Test.Lamdu.Env (Env)
import           Test.Lamdu.Gui (verifyLayers)
import           Test.Lamdu.Instances ()
import           Test.Lamdu.Sugar (convertWorkArea, testProgram)
import           Tests.Momentu (simpleKeyEvent)
import           Unsafe.Coerce (unsafeCoerce)

import           Test.Lamdu.Prelude

type T = Transaction

test :: Test
test =
    testGroup "gui-tests"
    [ testOpPrec
    , testFragmentSize
    , testLambdaDelete
    , testPrograms
    ]

replExpr ::
    Lens.Traversal' (Sugar.WorkArea name i o a)
    (Tree (Sugar.Body name i o) (Ann a))
replExpr = Sugar.waRepl . Sugar.replExpr . val . Sugar._BinderExpr

wideFocused :: Lens.Traversal' (Responsive a) (Widget.Surrounding -> Widget.Focused a)
wideFocused = Responsive.rWide . Align.tValue . Widget.wState . Widget._StateFocused

makeGui :: String -> Env -> T ViewM (Gui Responsive (T ViewM))
makeGui afterDoc env =
    do
        workArea <- convertWorkArea env
        let repl = workArea ^. Sugar.waRepl . Sugar.replExpr
        let replExprId = repl ^. SugarLens.binderResultExpr & WidgetIds.fromExprPayload
        gui <-
            do
                replGui <-
                    ExprGuiM.makeBinder repl
                    & GuiState.assignCursor WidgetIds.replId replExprId
                paneGuis <-
                    workArea ^.. Sugar.waPanes . traverse . Sugar.paneDefinition
                    & traverse (DefinitionEdit.make mempty)
                Responsive.vbox ?? (replGui : paneGuis)
            & ExprGuiM.run ExpressionEdit.make BinderEdit.make DbLayout.guiAnchors env id
        if Lens.has wideFocused gui
            then pure gui
            else fail ("Red cursor after " ++ afterDoc ++ ": " ++ show (env ^. cursor))

focusedWidget :: HasCallStack => Responsive a -> Either String (Widget.Focused a)
focusedWidget gui =
    widget <$ verifyLayers (widget ^. Widget.fLayers)
    where
        widget = (gui ^?! wideFocused) (Widget.Surrounding 0 0 0 0)

makeFocusedWidget ::
    String -> Env -> T ViewM (Widget.Focused (T ViewM GuiState.Update))
makeFocusedWidget afterDoc env =
    makeGui afterDoc env >>= either fail pure . focusedWidget

mApplyEvent ::
    Env -> VirtualCursor -> Event -> T ViewM (Maybe GuiState.Update)
mApplyEvent env virtCursor event =
    do
        w <- makeFocusedWidget "mApplyEvent" env
        let eventMap =
                (w ^. Widget.fEventMap)
                Widget.EventContext
                { Widget._eVirtualCursor = virtCursor
                , Widget._ePrevTextRemainder = ""
                }
        E.lookup (Identity Nothing) event eventMap
            & runIdentity
            <&> (^. E.dhHandler)
            & sequenceA

applyEvent :: Env -> VirtualCursor -> Event -> T ViewM Env
applyEvent env virtCursor event =
    mApplyEvent env virtCursor event <&> (^?! Lens._Just)
    <&> (`GuiState.update` env)

fromWorkArea ::
    Env -> Lens.ATraversal'
    (Sugar.WorkArea (Name (T ViewM)) (T ViewM) (T ViewM)
        (Sugar.Payload (Name (T ViewM)) (T ViewM) (T ViewM) ExprGui.Payload)) a ->
    T ViewM a
fromWorkArea env path = convertWorkArea env <&> (^?! Lens.cloneTraversal path)

dummyVirt :: VirtualCursor
dummyVirt = VirtualCursor (Rect 0 0)

-- | Test for issue #411
-- https://trello.com/c/IF6kY9AZ/411-deleting-lambda-parameter-red-cursor
testLambdaDelete :: Test
testLambdaDelete =
    testCase "delete-lambda" $
    Env.make >>=
    \baseEnv ->
    testProgram "simple-lambda.json" $
    do
        paramCursor <-
            fromWorkArea baseEnv
            (replExpr . Sugar._BodyLam . Sugar.lamFunc .
             Sugar.fParams . Sugar._Params . Lens.ix 0 . Sugar.fpInfo .
             Sugar.piTag . Sugar.tagInfo . Sugar.tagInstance)
            <&> WidgetIds.fromEntityId
        let delEvent = MetaKey noMods GLFW.Key'Backspace & simpleKeyEvent
        env0 <- applyEvent (baseEnv & cursor .~ paramCursor) dummyVirt delEvent
        -- One delete replaces the param tag, next delete deletes param
        env1 <- applyEvent env0 dummyVirt delEvent
        _ <- makeGui "" env1
        pure ()

-- | Test for issue #410
-- https://trello.com/c/00mxkLRG/410-navigating-to-fragment-affects-layout
testFragmentSize :: Test
testFragmentSize =
    testCase "fragment-size" $
    Env.make >>=
    \baseEnv ->
    testProgram "simple-fragment.json" $
    do
        frag <-
            fromWorkArea baseEnv
            (Sugar.waRepl . Sugar.replExpr . ann)
        guiCursorOnFrag <-
            baseEnv
            & cursor .~ WidgetIds.fromExprPayload frag
            & makeGui ""
        guiCursorElseWhere <- makeGui "" baseEnv
        unless (guiCursorOnFrag ^. sz == guiCursorElseWhere ^. sz) (fail "fragment size inconsistent")
    where
        sz = Responsive.rWide . Align.tValue . Element.size

-- | Test for issue #375
-- https://trello.com/c/KFLJPNmO/375-operator-precedence-crosses-lambda-boundaries-add-test
testOpPrec :: HasCallStack => Test
testOpPrec =
    testCase "apply-operator" $
    Env.make >>=
    \baseEnv ->
    testProgram "simple-lambda.json" $
    do
        holeId <-
            fromWorkArea baseEnv
            (replExpr . Sugar._BodyLam . Sugar.lamFunc .
             Sugar.fBody . ann . Sugar.plEntityId)
            <&> HoleWidgetIds.make
            <&> HoleWidgetIds.hidClosed
        workArea <- convertWorkArea baseEnv
        _ <- applyEvent (baseEnv & cursor .~ holeId) dummyVirt (EventChar '&')
        workArea' <- convertWorkArea baseEnv
        unless (workAreaEq workArea workArea') (fail "bad operator precedence")

workAreaEq ::
    forall a m.
    Eq a =>
    Sugar.WorkArea (Name (T m)) (T m) (T m)
    (Sugar.Payload (Name (T m)) (T m) (T m) a) ->
    Sugar.WorkArea (Name (T m)) (T m) (T m)
    (Sugar.Payload (Name (T m)) (T m) (T m) a) ->
    Bool
workAreaEq x y =
    x' == unsafeCoerce y
    where
        x' =
            unsafeCoerce x ::
                Sugar.WorkArea (Name Unit) Unit Unit
                (Sugar.Payload (Name Unit) Unit Unit a)

testKeyboardDirAndBack ::
    HasCallStack => Env.Env -> VirtualCursor ->
    MetaKey -> MetaKey -> T ViewM ()
testKeyboardDirAndBack posEnv posVirt way back =
    mApplyEvent posEnv posVirt (simpleKeyEvent way)
    >>=
    \case
    Nothing -> pure ()
    Just updThere ->
        mApplyEvent
        (GuiState.update updThere posEnv)
        (updThere ^?! GuiState.uVirtualCursor . traverse)
        (simpleKeyEvent back)
        >>=
        \case
        Nothing -> fail (baseInfo <> "can't move back with cursor keys")
        Just updBack | updBack ^? GuiState.uCursor . traverse /= Just (posEnv ^. cursor) ->
            baseInfo <> "moving back with cursor keys goes to different place: " <>
            show (updBack ^. GuiState.uCursor)
            & fail
        Just{} -> pure ()
    where
        baseInfo = show (posEnv ^. GuiState.cursor, way, back) <> ": "

comparePositions :: Rect -> Rect -> Ordering
comparePositions (Rect p0 s0) (Rect p1 s1) =
    compare (p0 ^. _2) (p1 ^. _2) <> compare (p0 ^. _1) (p1 ^. _1) <>
    compare (s0 ^. _2) (s1 ^. _2) <> compare (s0 ^. _1) (s1 ^. _1)

rectWithin :: Rect -> Rect -> Bool
rectWithin (Rect (Vector2 x0 y0) (Vector2 w0 h0)) (Rect (Vector2 x1 y1) (Vector2 w1 h1)) =
    x0 >= x1 && y0 >= y1 && x0 + w0 <= x1 + w1 && y0 + h0 <= h1 + h1

testTabNavigation :: HasCallStack => Env.Env -> VirtualCursor -> T ViewM ()
testTabNavigation env virtCursor =
    do
        w0 <- makeFocusedWidget "mApplyEvent" env
        let eventMap =
                (w0 ^. Widget.fEventMap)
                Widget.EventContext
                { Widget._eVirtualCursor = virtCursor
                , Widget._ePrevTextRemainder = ""
                }
        let testDir (name, event, expected) =
                E.lookup (Identity Nothing) event eventMap
                    & runIdentity <&> (^. E.dhHandler) & sequenceA
                >>=
                \case
                Nothing -> pure ()
                Just upd ->
                    do
                        w1 <-
                            makeFocusedWidget "testTabNavigation"
                            (GuiState.update upd env)
                        let p0 = w0 ^?! pos
                        let p1 = w1 ^?! pos
                        if comparePositions p1 p0 == expected || rectWithin p0 p1 || rectWithin p1 p0
                            then
                                -- TODO: Is/when-is it ok that tab goes to an outer/inner rect?
                                pure ()
                            else
                                show (env ^. GuiState.cursor) <> ": " <> name <>
                                " did not move to expected direction"
                                & fail
        traverse_ testDir dirs
    where
        pos = Widget.fFocalAreas . traverse
        dirs =
            [ ("tab", simpleKeyEvent (head Widget.strollAheadKeys), GT)
            , ("shift-tab", simpleKeyEvent (head Widget.strollBackKeys), LT)
            ]

testConsistentKeyboardNavigation :: Env.Env -> VirtualCursor -> T ViewM ()
testConsistentKeyboardNavigation posEnv posVirt =
    do
        unless (isLiteralEditId (posEnv ^. cursor))
            -- TODO: Handle literal edits properly
            ( traverse_ (uncurry (testKeyboardDirAndBack posEnv posVirt))
            [ (k GLFW.Key'Up, k GLFW.Key'Down)
            , (k GLFW.Key'Down, k GLFW.Key'Up)
            , (k GLFW.Key'Left, k GLFW.Key'Right)
            , (k GLFW.Key'Right, k GLFW.Key'Left)
            ]
            )
        testTabNavigation posEnv posVirt
    where
        isLiteralEditId wid =
            Widget.toAnimId wid & Lens.has (Lens.ix 1 . Lens.only "literal edit")
        k = MetaKey noMods

testActions :: Env.Env -> VirtualCursor -> T ViewM ()
testActions env virtCursor =
    do
        w <- makeFocusedWidget "" env
        (w ^. Widget.fEventMap)
            Widget.EventContext
            { Widget._eVirtualCursor = virtCursor
            , Widget._ePrevTextRemainder = ""
            }
            ^.. (E.emKeyMap . traverse . Lens.filteredBy E.dhDoc <. (E.dhHandler . E._Doesn'tWantClipboard)) . Lens.withIndex
            & traverse_ testEvent
    where
        testEvent (doc, event) =
            event <&> (`GuiState.update` env)
            >>= makeGui (show doc <> " from " <> show (env ^. cursor))
            & Transaction.fork & void

testProgramGuiAtPos ::
    Env.Env -> Widget.EnterResult (T ViewM GuiState.Update) -> T ViewM ()
testProgramGuiAtPos baseEnv enter =
    do
        upd <- enter ^. Widget.enterResultEvent
        let newEnv = GuiState.update upd baseEnv
        testConsistentKeyboardNavigation newEnv virtCursor
        testActions newEnv virtCursor
    where
        virtCursor = VirtualCursor (enter ^. Widget.enterResultRect)

nubOn :: Ord k => (a -> k) -> [a] -> [a]
nubOn f xs = (xs <&> (\x -> (f x, x)) & Map.fromList) ^.. Lens.folded

programTest :: HasCallStack => Env.Env -> FilePath -> Test
programTest baseEnv filename =
    testCase filename . testProgram filename $
    do
        baseGui <- makeGui "" baseEnv
        let size = baseGui ^. Responsive.rWide . Align.tValue . Widget.wSize
        w <- focusedWidget baseGui & either fail pure
        let enterPoint =
                w ^. Widget.fMEnterPoint
                & fromMaybe (error "unfocused widget from focusedWidget")
        Vector2 <$> [0, 0.1 .. 1] <*> [0, 0.3 .. 1] <&> (* size)
            <&> enterPoint
            & nubOn (^. Widget.enterResultRect)
            & traverse_ (testProgramGuiAtPos baseEnv)

testPrograms :: Test
testPrograms =
    do
        baseEnv <- Env.make
        listDirectory "test/programs"
            <&> filter (`notElem` skipped)
            <&> Lens.mapped %~ programTest baseEnv
            <&> testGroup "program-tests"
    & buildTest
    where
        skipped =
            [ -- The tests import a program without first importing freshdb.
              -- This program, saved with an old codec (the first version),
              -- is not compatible with that
              "old-codec-factorial.json"
            , "let-with-global-reference.json"
            ]
