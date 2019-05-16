{-# LANGUAGE TemplateHaskell, NamedFieldPuns, DisambiguateRecordFields #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit.ResultGroups
    ( makeAll
    , Result(..)
    , ResultGroup(..), rgPrefixId, rgMain, rgExtra
    ) where

import           AST.Knot.Ann (val)
import qualified Control.Lens as Lens
import           Control.Monad.ListT (ListT)
import qualified Data.ByteString.Char8 as BS8
import           Data.Function (on)
import           Data.List (sortOn, nubBy)
import qualified Data.List.Class as ListClass
import           Data.MRUMemo (memo)
import qualified Data.Text as Text
import qualified GUI.Momentu.Widget.Id as WidgetId
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified GUI.Momentu.Widgets.Menu.Search as SearchMenu
import qualified Lamdu.Calc.Lens as ExprLens
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Config as Config
import           Lamdu.Fuzzy (Fuzzy)
import qualified Lamdu.Fuzzy as Fuzzy
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.ValTerms as ValTerms
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import qualified Lamdu.I18N.Code as Texts
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

data Group i o = Group
    { _groupSearchTerms :: [Text]
    , _groupId :: WidgetId.Id
    , _groupResults ::
        ListT i
        ( Sugar.HoleResultScore
        , i (Sugar.HoleResult (Name o) i o)
        )
    }
Lens.makeLenses ''Group

data Result i o = Result
    { _rScore :: Sugar.HoleResultScore
    , -- Warning: This action should be ran at most once!
      -- Running it more than once will cause inconsistencies.
      rHoleResult :: i (Sugar.HoleResult (Name o) i o)
        -- TODO: Unit monad instead of i o for Expression above?
    , rId :: WidgetId.Id
    }
Lens.makeLenses ''Result

data IsExactMatch = ExactMatch | NotExactMatch
    deriving (Eq, Ord)

data ResultGroup i o = ResultGroup
    { _rgExactMatch :: IsExactMatch -- Move to top of result list
    , _rgPrefixId :: WidgetId.Id
    , _rgMain :: Result i o
    , _rgExtra :: [Result i o]
    }
Lens.makeLenses ''ResultGroup

mResultGroupOf ::
    WidgetId.Id ->
    [ ( Sugar.HoleResultScore
      , i (Sugar.HoleResult (Name o) i o)
      )
    ] ->
    Maybe (ResultGroup i o)
mResultGroupOf _ [] = Nothing
mResultGroupOf prefixId (x:xs) = Just
    ResultGroup
    { _rgExactMatch = NotExactMatch
    , _rgPrefixId = prefixId
    , _rgMain = mkResult prefixId x
    , _rgExtra = Lens.imap mkExtra xs
    }
    where
        mkExtra = mkResult . extraResultId
        extraResultId i = WidgetId.joinId extraResultsPrefixId [BS8.pack (show i)]
        extraResultsPrefixId = prefixId <> WidgetId.Id ["extra results"]
        mkResult resultId (score, holeResult) =
            Result
            { _rScore = score
            , rHoleResult = holeResult
            , rId = resultId
            }

makeResultGroup ::
    Monad i =>
    SearchMenu.ResultsContext -> Group i o ->
    i (Maybe (ResultGroup i o))
makeResultGroup ctx group =
    group ^. groupResults
    & ListClass.toList
    <&> sortOn fst
    <&> mResultGroupOf (ctx ^. SearchMenu.rResultIdPrefix <> (group ^. groupId))
    <&> Lens.mapped %~ rgExactMatch .~ toExactMatch
    where
        searchTerm = ctx ^. SearchMenu.rSearchTerm
        toExactMatch
            | any (`elem` group ^. groupSearchTerms)
              [searchTerm, ValTerms.definitePart searchTerm] = ExactMatch
            | otherwise = NotExactMatch

data GoodAndBad a = GoodAndBad { _good :: a, _bad :: a }
    deriving (Functor, Foldable, Traversable)
Lens.makeLenses ''GoodAndBad

collectResults ::
    Monad i =>
    Config.Completion -> ListT i (ResultGroup i o) ->
    i (Menu.OptionList (ResultGroup i o))
collectResults config resultsM =
    do
        (tooFewGoodResults, moreResultsM) <-
            ListClass.scanl prependResult (GoodAndBad [] []) resultsM
            & ListClass.splitWhenM (pure . (>= resCount) . length . _good)

        -- We need 2 of the moreResultsM:
        -- A. First is needed because it would be the first to have the correct
        --    number of good results
        -- B. Second is needed just to determine if there are any
        --    remaining results beyond it
        moreResults <- ListClass.take 2 moreResultsM & ListClass.toList

        tooFewGoodResults ++ moreResults
            & last
            & traverse %~ reverse
            & concatBothGoodAndBad
            & sortOn resultsListScore
            -- Re-split because now that we've added all the
            -- accumulated bad results we may have too many
            & splitAt resCount
            & _2 %~ not . null
            & uncurry Menu.toOptionList
            & pure
    where
        resCount = config ^. Config.completionResultCount
        concatBothGoodAndBad goodAndBad = goodAndBad ^. Lens.folded
        resultsListScore x = (x ^. rgExactMatch, x ^. rgMain . rScore & isGoodResult & not)
        prependResult results x =
            results
            & case (x ^. rgExactMatch, x ^. rgMain . rScore & isGoodResult) of
                (NotExactMatch, False) -> bad
                _ -> good
                %~ (x :)

isGoodResult :: Sugar.HoleResultScore -> Bool
isGoodResult hrs = hrs ^. Sugar.hrsNumFragments == 0

makeAll ::
    (Monad i, Has (Texts.Code Text) env) =>
    [Sugar.HoleOption (Name o1) i o1] ->
    SearchMenu.ResultsContext ->
    ExprGuiM env i o (Menu.OptionList (ResultGroup i o1))
makeAll options ctx =
    do
        config <- Lens.view (has . Config.completion)
        env <- Lens.view id
        traverse (mkGroup env) options
            <&> holeMatches searchTerm
            <&> ListClass.fromList
            <&> ListClass.mapL (makeResultGroup ctx)
            <&> ListClass.catMaybes
            >>= collectResults config
            & ExprGuiM.im
    where
        searchTerm = ctx ^. SearchMenu.rSearchTerm

mkGroupId :: Show a => Val a -> WidgetId.Id
mkGroupId option =
    option
    & ExprLens.valLeafs . V._LLiteral . V.primData .~ mempty
    & WidgetIds.hash

mkGroup ::
    ( Monad i
    , Has (Texts.Code Text) env
    ) =>
    env ->
    Sugar.HoleOption (Name o) i o ->
    i (Group i o)
mkGroup env option =
    option ^. Sugar.hoSugaredBaseExpr
    <&>
    \sugaredBaseExpr ->
    Group
    { _groupSearchTerms =
        sugaredBaseExpr ^. val & ValTerms.binder env
    , _groupResults = option ^. Sugar.hoResults
    , _groupId = mkGroupId (option ^. Sugar.hoVal)
    }

unicodeAlts :: Text -> [Text]
unicodeAlts haystack =
    traverse alts (Text.unpack haystack)
    <&> concat
    <&> Text.pack
    where
        alts x = [x] : extras x
        extras '≥' = [">="]
        extras '≤' = ["<="]
        extras '≠' = ["/=", "!=", "<>"]
        extras '⋲' = ["<{"]
        extras 'α' = ["alpha"]
        extras 'β' = ["beta"]
        extras _ = []

{-# NOINLINE fuzzyMaker #-}
fuzzyMaker :: [(Text, Int)] -> Fuzzy (Set Int)
fuzzyMaker = memo Fuzzy.make

holeMatches :: Monad i => Text -> [Group i o] -> [Group i o]
holeMatches searchTerm groups =
    groups ^@.. Lens.ifolded
    <&> (\(idx, group) -> searchTerms group <&> ((,) ?? (idx, group)))
    & concat
    & (Fuzzy.memoableMake fuzzyMaker ?? searchText)
    <&> snd
    & nubBy ((==) `on` fst)
    <&> snd
    <&> groupResults %~ ListClass.filterL (fmap isHoleResultOK . snd)
    where
        searchText = ValTerms.definitePart searchTerm
        searchTerms group =
            case group ^. groupSearchTerms of
            [] -> [""]
            terms -> terms >>= unicodeAlts
        isHoleResultOK =
            ValTerms.verifyInjectSuffix searchTerm . (^. Sugar.holeResultConverted . SugarLens.binderResultExpr . Lens.asIndex)
