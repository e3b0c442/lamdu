{-# LANGUAGE ExistentialQuantification, TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Lamdu.Sugar.Convert.Hole
    ( convert
      -- Used by Convert.Fragment:
    , StorePoint, ResultVal, Preconversion, ResultGen
    , ResultProcessor(..)
    , mkOptions, detachValIfNeeded, sugar, loadNewDeps
    , mkResult
    , mkOption, addWithoutDups
    , assertSuccessfulInfer
    ) where

import           AST (Tree, Pure(..), _ToKnot, _Pure)
import           AST.Infer (IResult(..), irType, irScope, infer)
import           AST.Knot.Ann (Ann(..), ann, annotations)
import           AST.Term.FuncType (FuncType(..))
import           AST.Term.Nominal (ToNom(..), NominalDecl, nScheme)
import           AST.Term.Row (freExtends)
import           AST.Term.Scheme (sTyp)
import           AST.Unify (unify, newTerm, applyBindings)
import           AST.Unify.Binding (UVar)
import           Control.Applicative (Alternative(..))
import qualified Control.Lens as Lens
import           Control.Monad ((>=>), filterM)
import           Control.Monad.ListT (ListT)
import           Control.Monad.Reader (local)
import           Control.Monad.State (State, StateT(..), mapStateT, evalState, state)
import qualified Control.Monad.State as State
import           Control.Monad.Transaction (transaction)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.Binary as Binary
import           Data.Bits (xor)
import qualified Data.ByteString.Extended as BS
import           Data.CurAndPrev (CurAndPrev(..))
import qualified Data.List.Class as ListClass
import qualified Data.Map as Map
import           Data.Property (MkProperty')
import qualified Data.Property as Property
import           Data.Semigroup (Endo)
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import qualified Lamdu.Annotations as Annotations
import           Lamdu.Calc.Definition (Deps(..), depsGlobalTypes, depsNominals)
import           Lamdu.Calc.Infer (InferState, runPureInfer, PureInfer)
import qualified Lamdu.Calc.Infer as Infer
import qualified Lamdu.Calc.Lens as ExprLens
import qualified Lamdu.Calc.Pure as P
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import           Lamdu.Calc.Term.Eq (couldEq)
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Definition as Def
import qualified Lamdu.Expr.GenIds as GenIds
import           Lamdu.Expr.IRef (ValP, ValI, DefI)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Load as Load
import           Lamdu.Sugar.Annotations (neverShowAnnotations, alwaysShowAnnotations)
import qualified Lamdu.Sugar.Config as Config
import           Lamdu.Sugar.Convert.Binder (convertBinder)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions, convertPayload, makeSetToLiteral)
import           Lamdu.Sugar.Convert.Hole.ResultScore (resultScore)
import qualified Lamdu.Sugar.Convert.Hole.Suggest as Suggest
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types
import qualified Revision.Deltum.IRef as IRef
import           Revision.Deltum.Transaction (Transaction)
import qualified Revision.Deltum.Transaction as Transaction
import           System.Random (random)
import qualified System.Random.Extended as Random
import           Text.PrettyPrint.HughesPJClass (prettyShow)

import           Lamdu.Prelude

type T = Transaction

type StorePoint m a = (Maybe (ValI m), a)

type ResultVal m a = Val (StorePoint m a, IResult UVar V.Term)

type Preconversion m a = Val (Input.Payload m a) -> Val (Input.Payload m ())

type ResultGen m = StateT InferState (ListT (T m))

convert :: (Monad m, Monoid a) => Input.Payload m a -> ConvertM m (ExpressionU m a)
convert holePl =
    Hole
    <$> mkOptions holeResultProcessor holePl
    <*> makeSetToLiteral holePl
    <*> pure Nothing
    <&> BodyHole
    >>= addActions [] holePl
    <&> ann . pActions . mSetToHole .~ Nothing

data ResultProcessor m = forall a. ResultProcessor
    { rpEmptyPl :: a
    , rpPostProcess :: ResultVal m () -> ResultGen m (ResultVal m a)
    , rpPreConversion :: Preconversion m a
    }

holeResultProcessor :: Monad m => ResultProcessor m
holeResultProcessor =
    ResultProcessor
    { rpEmptyPl = ()
    , rpPostProcess = pure
    , rpPreConversion = id
    }

mkOption ::
    Monad m =>
    ConvertM.Context m -> ResultProcessor m -> Input.Payload m a -> Val () ->
    HoleOption InternalName (T m) (T m)
mkOption sugarContext resultProcessor holePl x =
    HoleOption
    { _hoVal = x
    , _hoSugaredBaseExpr = sugar sugarContext holePl x
    , _hoResults = mkResults resultProcessor sugarContext holePl x
    }

mkHoleSuggesteds ::
    Monad m =>
    ConvertM.Context m -> ResultProcessor m -> Input.Payload m a ->
    [HoleOption InternalName (T m) (T m)]
mkHoleSuggesteds sugarContext resultProcessor holePl =
    holePl ^. Input.inferResult . irType
    & Suggest.forType
    & runPureInfer (holePl ^. Input.inferResult . irScope) inferContext

    -- TODO: Change ConvertM to be stateful rather than reader on the
    -- sugar context, to collect union-find updates.
    -- TODO: use a specific monad here that has no Either
    & assertSuccessfulInfer
    & fst
    <&> annotations .~ () -- TODO: "Avoid re-inferring known type here"
    <&> mkOption sugarContext resultProcessor holePl
    where
        inferContext = sugarContext ^. ConvertM.scInferContext

addWithoutDups ::
    [HoleOption i o a] -> [HoleOption i o a] -> [HoleOption i o a]
addWithoutDups new old
    | null nonHoleNew = old
    | otherwise = nonHoleNew ++ filter (not . equivalentToNew) old
    where
        equivalentToNew x =
            any (couldEq (x ^. hoVal)) (nonHoleNew ^.. Lens.traverse . hoVal)
        nonHoleNew = filter (Lens.nullOf (hoVal . ExprLens.valHole)) new

isLiveGlobal :: Monad m => DefI m -> T m Bool
isLiveGlobal defI =
    Anchors.assocDefinitionState defI
    & Property.getP
    <&> (== LiveDefinition)

getListing ::
    Monad m =>
    (Anchors.CodeAnchors f -> MkProperty' (T m) (Set a)) ->
    ConvertM.Context f -> T m [a]
getListing anchor sugarContext =
    sugarContext ^. ConvertM.scCodeAnchors
    & anchor & Property.getP <&> Set.toList

getNominals :: Monad m => ConvertM.Context m -> T m [(T.NominalId, Tree Pure (NominalDecl T.Type))]
getNominals sugarContext =
    getListing Anchors.tids sugarContext
    >>= traverse (\nomId -> (,) nomId <$> Load.nominal nomId)
    <&> map (Lens.sequenceAOf Lens._2) <&> (^.. traverse . Lens._Just)

getGlobals :: Monad m => ConvertM.Context m -> T m [DefI m]
getGlobals sugarContext =
    getListing Anchors.globals sugarContext >>= filterM isLiveGlobal

getTags :: Monad m => ConvertM.Context m -> T m [T.Tag]
getTags = getListing Anchors.tags

mkNominalOptions :: [(T.NominalId, Tree Pure (NominalDecl T.Type))] -> [Val ()]
mkNominalOptions nominals =
    do
        (tid, MkPure nominal) <- nominals
        mkDirectNoms tid ++ mkToNomInjections tid nominal
    where
        mkDirectNoms tid =
            [ Apply (Ann () (V.BLeaf (V.LFromNom tid))) P.hole & V.BApp
            , ToNom tid P.hole & V.BToNom
            ] <&> Ann ()
        mkToNomInjections tid nominal =
            do
                tag <-
                    nominal ^..
                    nScheme . sTyp . _Pure . T._TVariant .
                    T.flatRow . freExtends >>= Map.keys
                let inject = V.Inject tag P.hole & V.BInject & Ann ()
                [ inject & ToNom tid & V.BToNom & Ann () ]

mkOptions ::
    Monad m =>
    ResultProcessor m -> Input.Payload m a ->
    ConvertM m (T m [HoleOption InternalName (T m) (T m)])
mkOptions resultProcessor holePl =
    Lens.view id
    <&>
    \sugarContext ->
    do
        nominalOptions <- getNominals sugarContext <&> mkNominalOptions
        globals <- getGlobals sugarContext
        tags <- getTags sugarContext
        concat
            [ holePl ^. Input.localsInScope >>= getLocalScopeGetVars sugarContext
            , globals <&> P.var . ExprIRef.globalId
            , tags <&> (`P.inject` P.hole)
            , nominalOptions
            , [ P.abs "NewLambda" P.hole
              , P.recEmpty
              , P.absurd
              , P.abs "NewLambda" P.hole P.$$ P.hole
              ]
            ]
            <&> mkOption sugarContext resultProcessor holePl
            & addWithoutDups (mkHoleSuggesteds sugarContext resultProcessor holePl)
            & pure

-- TODO: Generalize into a separate module?
loadDeps :: Monad m => [V.Var] -> [T.NominalId] -> T m Deps
loadDeps vars noms =
    Deps
    <$> (traverse loadVar vars <&> Map.fromList)
    <*> (traverse loadNom noms <&> Map.fromList)
    where
        loadVar globalId =
            ExprIRef.defI globalId & Transaction.readIRef
            <&> (^. Def.defType) <&> (,) globalId
        loadNom nomId =
            Load.nominal nomId
            <&> fromMaybe (error "Opaque nominal used!")
            <&> (,) nomId

type Getting' r a = Lens.Getting a r a
type Folding' r a = Lens.Getting (Endo [a]) r a

-- TODO: Generalize into a separate module?
loadNewDeps ::
    forall m a k.
    Monad m => Deps -> Tree V.Scope k -> Val a -> T m Deps
loadNewDeps currentDeps scope x =
    loadDeps newDepVars newNoms
    <&> mappend currentDeps
    where
        scopeVars = scope ^. V.scopeVarTypes & Map.keysSet
        newDeps ::
            Ord r =>
            Getting' Deps (Map r x) -> Folding' (Val a) r -> [r]
        newDeps depsLens valLens =
            Set.fromList (x ^.. valLens)
            `Set.difference` Map.keysSet (currentDeps ^. depsLens)
            & Set.toList
        newDepVars = newDeps depsGlobalTypes (ExprLens.valGlobals scopeVars)
        newNoms = newDeps depsNominals ExprLens.valNominals

-- Unstored and without eval results.
-- Used for hole's base exprs, to perform sugaring and get names from sugared exprs.
-- TODO: We shouldn't need to perform sugaring for base exprs, and this should be removed.
prepareUnstoredPayloads ::
    Val (IResult UVar V.Term, Tree Pure T.Type, EntityId, a) ->
    Val (Input.Payload m a)
prepareUnstoredPayloads v =
    v & annotations %~ mk & Input.preparePayloads
    where
        mk (inferPl, typ, eId, x) =
            ( eId
            , \varRefs ->
              Input.Payload
              { Input._varRefsOfLambda = varRefs
              , Input._userData = x
              , Input._localsInScope = []
              , Input._inferredType = typ
              , Input._inferResult = inferPl
              , Input._entityId = eId
              , Input._stored =
                Property.Property
                (_ToKnot # IRef.unsafeFromUUID fakeStored)
                (error "stored output of base expr used!")
              , Input._evalResults =
                CurAndPrev Input.emptyEvalResults Input.emptyEvalResults
              }
            )
            where
                -- TODO: Which code reads this?
                EntityId.EntityId fakeStored = eId

assertSuccessfulInfer ::
    HasCallStack =>
    Either (Tree Pure T.TypeError) a -> a
assertSuccessfulInfer = either (error . prettyShow) id

loadInfer ::
    Monad m =>
    ConvertM.Context m -> Tree V.Scope UVar -> Val a ->
    T m (Deps, Either (Tree Pure T.TypeError) (Val (a, IResult UVar V.Term), InferState))
loadInfer sugarContext scope v =
    loadNewDeps sugarDeps scope v
    <&>
    \deps ->
    ( deps
    , do
        addScope <- Infer.loadDeps deps
        local addScope (infer v)
        & runPureInfer scope (sugarContext ^. ConvertM.scInferContext)
        <&> _1 %~ (^. ExprLens.itermAnn)
    )
    where
        sugarDeps = sugarContext ^. ConvertM.scFrozenDeps . Property.pVal

sugar ::
    (Monad m, Monoid a) =>
    ConvertM.Context m -> Input.Payload m dummy -> Val a ->
    T m (Tree (Ann (Payload InternalName (T m) (T m) a)) (Binder InternalName (T m) (T m)))
sugar sugarContext holePl v =
    do
        (val, inferCtx) <-
            loadInfer sugarContext scope v
            <&> snd
            <&> assertSuccessfulInfer
            <&> makePayloads
            <&> _1 %~ (EntityId.randomizeExprAndParams . Random.genFromHashable)
                (holePl ^. Input.entityId)
            <&> _1 %~ prepareUnstoredPayloads
            <&> _1 %~ Input.initLocalsInScope (holePl ^. Input.localsInScope)
            & transaction
        convertBinder val
            <&> annotations %~ (,) neverShowAnnotations
            >>= annotations (convertPayload Annotations.None)
            & ConvertM.run (sugarContext & ConvertM.scInferContext .~ inferCtx)
    where
        scope = holePl ^. Input.inferResult . irScope
        makePayloads (term, inferCtx) =
            ( annotations mkPayload term
                & runPureInfer scope inferCtx
                & assertSuccessfulInfer
                & fst
            , inferCtx
            )
        mkPayload (x, inferPl) =
            applyBindings (inferPl ^. irType)
            <&>
            \typ entityId ->
            (inferPl, typ, entityId, x)

getLocalScopeGetVars :: ConvertM.Context m -> V.Var -> [Val ()]
getLocalScopeGetVars sugarContext par
    | sugarContext ^. ConvertM.scScopeInfo . ConvertM.siNullParams . Lens.contains par = []
    | otherwise = map mkFieldParam fieldTags ++ [var]
    where
        var = V.LVar par & V.BLeaf & Ann ()
        fieldTags =
            ( sugarContext ^@..
                ConvertM.scScopeInfo . ConvertM.siTagParamInfos .>
                ( Lens.itraversed <.
                    ConvertM._TagFieldParam . Lens.to ConvertM.tpiFromParameters ) <.
                    Lens.filtered (== par)
            ) <&> fst
        mkFieldParam tag = V.GetField var tag & V.BGetField & Ann ()

-- | Runs inside a forked transaction
writeResult ::
    Monad m =>
    Preconversion m a -> InferState -> ValP m -> ResultVal m a ->
    T m (Val (Input.Payload m ()))
writeResult preConversion inferContext holeStored inferredVal =
    do
        writtenExpr <-
            inferredVal
            & annotations %~ intoStorePoint
            & writeExprMStored (Property.value holeStored)
            <&> ExprIRef.addProperties (holeStored ^. Property.pSet)
            <&> addBindingsAll
            <&> annotations %~ toPayload
            <&> Input.preparePayloads
            <&> annotations %~ snd
        (holeStored ^. Property.pSet) (writtenExpr ^. ann . _1 . Property.pVal)
        writtenExpr & annotations %~ snd & preConversion & pure
    where
        intoStorePoint ((mStorePoint, a), inferred) =
            (mStorePoint, (inferred, Lens.has Lens._Just mStorePoint, a))
        toPayload (stored, (inferRes, resolved, wasStored, a)) =
            -- TODO: Evaluate hole results instead of Map.empty's?
            ( eId
            , \varRefs ->
              ( wasStored
              , ( stored
                , Input.Payload
                  { Input._varRefsOfLambda = varRefs
                  , Input._userData = a
                  , Input._inferredType = resolved
                  , Input._inferResult = inferRes
                  , Input._evalResults = CurAndPrev noEval noEval
                  , Input._stored = stored
                  , Input._entityId = eId
                  , Input._localsInScope = []
                  }
                )
              )
            )
            where
                eId = Property.value stored & EntityId.ofValI
        noEval = Input.EvalResultsForExpr Map.empty Map.empty
        addBindingsAll x =
            (annotations . Lens._2) addBindings x
            & runPureInfer (x ^. ann . Lens._2 . Lens._1 . irScope) inferContext
            & assertSuccessfulInfer
            & fst
        addBindings (inferRes, wasStored, a) =
            applyBindings (inferRes ^. irType)
            <&>
            \resolved -> (inferRes, resolved, wasStored, a)

detachValIfNeeded ::
    a -> IResult UVar V.Term -> Val (a, IResult UVar V.Term) ->
    -- TODO: PureInfer?
    State InferState (Val (a, IResult UVar V.Term))
detachValIfNeeded emptyPl holeIRes x =
    do
        unifyRes <-
            do
                r <- unify (holeIRes ^. irType) xType
                -- Verify occurs checks.
                -- TODO: share with applyBindings that happens for sugaring.
                s <- State.get
                _ <- annotations (applyBindings . (^. _2 . irType)) x
                r <$ State.put s
            & liftPureInfer
        let mkFragmentExpr =
                FuncType xType holeType & T.TFun & newTerm
                <&> \funcType ->
                let withTyp typ =
                        Ann (emptyPl, x ^. ann . _2 & irType .~ typ)
                    func = V.BLeaf V.LHole & withTyp funcType
                in  func `V.Apply` x & V.BApp & withTyp holeType
        case unifyRes of
            Right{} -> pure x
            Left{} ->
                liftPureInfer mkFragmentExpr
                <&> assertSuccessfulInfer
    where
        xType = x ^. ann . _2 . irType
        liftPureInfer ::
            PureInfer a -> State InferState (Either (Tree Pure T.TypeError) a)
        liftPureInfer act =
            do
                st <- Lens.use id
                runPureInfer scope st act
                    & Lens._Right %%~ \(r, newSt) -> r <$ (id .= newSt)
        holeType = holeIRes ^. irType
        scope = holeIRes ^. irScope

mkResultVals ::
    Monad m =>
    ConvertM.Context m -> Tree V.Scope UVar -> Val () ->
    ResultGen m (Deps, ResultVal m ())
mkResultVals sugarContext scope seed =
    -- TODO: This uses state from context but we're in StateT.
    -- This is a mess..
    loadInfer sugarContext scope seed & txn
    >>=
    \case
    (_, Left{}) -> empty
    (newDeps, Right (inferResult, newInferState)) ->
        do
            id .= newInferState
            form <-
                Suggest.termTransformsWithModify () inferResult
                & mapStateT ListClass.fromList
            pure (newDeps, form & annotations . _1 %~ (,) Nothing)
    where
        txn = lift . lift

mkResult ::
    Monad m =>
    Preconversion m a -> ConvertM.Context m -> T m () -> Input.Payload m b ->
    ResultVal m a ->
    T m (HoleResult InternalName (T m) (T m))
mkResult preConversion sugarContext updateDeps holePl x =
    do
        updateDeps
        writeResult preConversion (sugarContext ^. ConvertM.scInferContext)
            (holePl ^. Input.stored) x
        <&> Input.initLocalsInScope (holePl ^. Input.localsInScope)
        <&> (convertBinder >=> annotations (convertPayload Annotations.None) . (annotations %~ (,) showAnn))
        >>= ConvertM.run sugarContext
        & Transaction.fork
        <&> \(fConverted, forkedChanges) ->
        HoleResult
        { _holeResultConverted = fConverted
        , _holeResultPick =
            do
                Transaction.merge forkedChanges
                -- TODO: Remove this 'run', mkResult to be wholly in ConvertM
                ConvertM.run sugarContext ConvertM.postProcessAssert & join
        }
    where
        showAnn
            | sugarContext ^. ConvertM.scConfig . Config.showAllAnnotations = alwaysShowAnnotations
            | otherwise = neverShowAnnotations

toStateT :: Applicative m => State s a -> StateT s m a
toStateT = mapStateT $ \(Lens.Identity act) -> pure act

toScoredResults ::
    (Monad f, Monad m) =>
    a -> Preconversion m a -> ConvertM.Context m -> Input.Payload m dummy ->
    StateT InferState f (Deps, ResultVal m a) ->
    f ( HoleResultScore
      , T m (HoleResult InternalName (T m) (T m))
      )
toScoredResults emptyPl preConversion sugarContext holePl act =
    act
    >>= _2 %%~ toStateT . detachValIfNeeded (Nothing, emptyPl) holeInferRes
    & (`runStateT` (sugarContext ^. ConvertM.scInferContext))
    <&> \((newDeps, x), inferContext) ->
    let newSugarContext =
            sugarContext
            & ConvertM.scInferContext .~ inferContext
            & ConvertM.scFrozenDeps . Property.pVal .~ newDeps
        updateDeps = newDeps & sugarContext ^. ConvertM.scFrozenDeps . Property.pSet
    in  ( x & annotations %%~ applyBindings . (^. Lens._2 . irType)
          & runPureInfer (holeInferRes ^. irScope) inferContext
          & assertSuccessfulInfer
          & fst
          & resultScore
        , mkResult preConversion newSugarContext updateDeps holePl x
        )
    where
        holeInferRes = holePl ^. Input.inferResult

mkResults ::
    Monad m =>
    ResultProcessor m -> ConvertM.Context m -> Input.Payload m dummy -> Val () ->
    ListT (T m)
    ( HoleResultScore
    , T m (HoleResult InternalName (T m) (T m))
    )
mkResults (ResultProcessor emptyPl postProcess preConversion) sugarContext holePl base =
    mkResultVals sugarContext (holePl ^. Input.inferResult . irScope) base
    >>= _2 %%~ postProcess
    & toScoredResults emptyPl preConversion sugarContext holePl

xorBS :: ByteString -> ByteString -> ByteString
xorBS x y = BS.pack $ BS.zipWith xor x y

randomizeNonStoredParamIds ::
    Random.StdGen -> Val (StorePoint m a) -> Val (StorePoint m a)
randomizeNonStoredParamIds gen =
    GenIds.randomizeParamIdsG id nameGen Map.empty $ \_ _ pl -> pl
    where
        nameGen = GenIds.onNgMakeName f $ GenIds.randomNameGen gen
        f n _        prevEntityId (Just _, _) = (prevEntityId, n)
        f _ prevFunc prevEntityId pl@(Nothing, _) = prevFunc prevEntityId pl

randomizeNonStoredRefs ::
    ByteString -> Random.StdGen -> Val (StorePoint m a) -> Val (StorePoint m a)
randomizeNonStoredRefs uniqueIdent gen v =
    evalState ((annotations . _1) f v) gen
    where
        f Nothing =
            state random
            <&> UUID.toByteString <&> BS.strictify
            <&> xorBS uniqueIdent
            <&> BS.lazify <&> UUID.fromByteString
            <&> fromMaybe (error "cant parse UUID")
            <&> IRef.unsafeFromUUID <&> (Lens._Just . _ToKnot #)
        f (Just x) = Just x & pure

writeExprMStored ::
    Monad m => ValI m -> Val (StorePoint m a) -> T m (Val (ValI m, a))
writeExprMStored exprIRef exprMStorePoint =
    exprMStorePoint
    & randomizeNonStoredParamIds genParamIds
    & randomizeNonStoredRefs uniqueIdent genRefs
    & ExprIRef.writeValWithStoredSubexpressions
    where
        uniqueIdent =
            Binary.encode
            ( exprMStorePoint & annotations %~ fst
            , exprIRef
            )
            & SHA256.hashlazy
        (genParamIds, genRefs) = Random.genFromHashable uniqueIdent & Random.split

