{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell, PolymorphicComponents, ConstraintKinds, FlexibleInstances, MultiParamTypeClasses #-}
module Lamdu.Sugar.Convert.Monad
    ( TagParamInfo(..)
    , TagFieldParam(..), _TagFieldParam, _CollidingFieldParam
    , OuterScopeInfo(..), osiPos, osiScope
    , RecursiveRef(..), rrDefI, rrDefType
    , ScopeInfo(..), siTagParamInfos, siNullParams, siLetItems, siMOuter

    , Context(..)
    , scInferContext, scPostProcessRoot, siRecursiveRef, scConfig
    , scCodeAnchors, scScopeInfo, scDebugMonitors, scCacheFunctions
    , scOutdatedDefinitions, scFrozenDeps, scInlineableDefinition

    , cachedFunc

    , ConvertM(..), run
    , local
    , convertSubexpression
    , typeProtectedSetToVal, postProcessAssert, postProcessWith
    ) where

import           AST (Tree, Pure)
import           AST.Unify.Binding (UVar)
import qualified Control.Lens as Lens
import           Control.Monad.Trans.Reader (ReaderT, runReaderT)
import qualified Control.Monad.Trans.Reader as Reader
import           Control.Monad.Transaction (MonadTransaction(..))
import           Data.Property (Property)
import qualified GUI.Momentu.Direction as Dir
import qualified Lamdu.Cache as Cache
import           Lamdu.Calc.Definition (Deps)
import           Lamdu.Calc.Infer (InferState)
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Data.Anchors as Anchors
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Debug as Debug
import qualified Lamdu.Expr.IRef as ExprIRef
import           Lamdu.I18N.LangId (LangId)
import           Lamdu.Sugar.Config (Config)
import qualified Lamdu.Sugar.Convert.Input as Input
import qualified Lamdu.Sugar.Convert.PostProcess as PostProcess
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Types as Sugar
import           Revision.Deltum.Transaction (Transaction)
import qualified Revision.Deltum.Transaction as Transaction
import           Text.PrettyPrint.HughesPJClass (prettyShow)

import           Lamdu.Prelude

type T = Transaction

data TagParamInfo = TagParamInfo
    { tpiFromParameters :: V.Var -- TODO: Rename "From" to something else
    , tpiJumpTo :: Sugar.EntityId
    }

data TagFieldParam
    = -- Sugared field param:
      TagFieldParam TagParamInfo
    | -- Colliding (and thus non-sugared) field param
      CollidingFieldParam TagParamInfo

data OuterScopeInfo m = OuterScopeInfo
    { _osiPos :: ExprIRef.ValP m
    , _osiScope :: Tree V.Scope UVar
    }
Lens.makeLenses ''OuterScopeInfo

data RecursiveRef m = RecursiveRef
    { _rrDefI :: ExprIRef.DefI m
    , _rrDefType :: Tree Pure T.Scheme
    }
Lens.makeLenses ''RecursiveRef

data ScopeInfo m = ScopeInfo
    { _siTagParamInfos :: Map T.Tag TagFieldParam -- tag uuids
    , _siNullParams :: Set V.Var
    , -- Each let item potentially has an inline action
      _siLetItems :: Map V.Var (Sugar.EntityId -> Sugar.BinderVarInline (T m))
      -- TODO: siTagParamInfos needs a reverse-lookup map too
    , -- Where "extract to let" goes:
      _siMOuter :: Maybe (OuterScopeInfo m)
    , -- The globals we artificially inject into the scope in order to
      -- infer their type supporting mutual recursions
      _siRecursiveRef :: Maybe (RecursiveRef m)
    }
Lens.makeLenses ''ScopeInfo

newtype ConvertM m a = ConvertM (ReaderT (Context m) (T m) a)
    deriving newtype (Functor, Applicative, Monad, MonadReader (Context m))

instance Monad m => MonadTransaction m (ConvertM m) where
    transaction = ConvertM . lift

data Context m = Context
    { _scInferContext :: InferState
    , _scCodeAnchors :: Anchors.CodeAnchors m
    , _scScopeInfo :: ScopeInfo m
    , -- Check whether the definition is valid after an edit,
      -- so that can detach bad edits.
      _scPostProcessRoot :: T m PostProcess.Result
    , _scOutdatedDefinitions :: Map V.Var (Sugar.DefinitionOutdatedType InternalName (T m ()))
    , _scInlineableDefinition :: V.Var -> Sugar.EntityId -> Bool
    , _scFrozenDeps :: Property (T m) Deps
    , _scDebugMonitors :: Debug.Monitors
    , _scCacheFunctions :: Cache.Functions
    , _scConfig :: Config
    , scConvertSubexpression ::
        forall a. Monoid a => Val (Input.Payload m a) -> ConvertM m (ExpressionU m a)
    , _scLanguageIdentifier :: LangId
    , _scLanguageDir :: Dir.Layout
    }
Lens.makeLenses ''Context
Lens.makePrisms ''TagFieldParam

instance Has LangId (Context m) where has = scLanguageIdentifier
instance Has Dir.Layout (Context m) where has = scLanguageDir

cachedFunc :: Monad m => (Cache.Functions -> a) -> ConvertM m a
cachedFunc f = Lens.view scCacheFunctions <&> f

typeProtect :: Monad m => T m PostProcess.Result -> T m a -> T m (Maybe a)
typeProtect checkOk act =
    do
        ((result, isOk), changes) <- (,) <$> act <*> checkOk & Transaction.fork
        case isOk of
            PostProcess.GoodExpr -> Just result <$ Transaction.merge changes
            PostProcess.BadExpr _ -> pure Nothing

typeProtectedSetToVal ::
    Monad m =>
    ConvertM m
    (ExprIRef.ValP m -> ExprIRef.ValI m -> T m (ExprIRef.ValI m))
typeProtectedSetToVal =
    Lens.view scPostProcessRoot
    <&> \checkOk dest valI ->
    do
        mResult <- DataOps.replace dest valI & typeProtect checkOk
        case mResult of
            Just result -> pure result
            Nothing ->
                do
                    res <- DataOps.setToAppliedHole valI dest
                    _ <- checkOk
                    pure res

postProcessWith :: Monad m => ConvertM m ((Tree Pure T.TypeError -> T m ()) -> T m ())
postProcessWith =
    Lens.view scPostProcessRoot
    <&> \postProcess onError ->
    postProcess
    >>=
    \case
    PostProcess.GoodExpr -> pure ()
    PostProcess.BadExpr err ->
        do
            onError err
            postProcess >>=
                \case
                PostProcess.GoodExpr -> pure ()
                PostProcess.BadExpr e -> fail ("postProcessWith onError failed: " <> prettyShow e)

postProcessAssert :: Monad m => ConvertM m (T m ())
postProcessAssert = postProcessWith ?? (fail . prettyShow)

run :: (HasCallStack, Monad m) => Context m -> ConvertM m a -> T m a
run ctx (ConvertM action) =
    runReaderT action ctx & report
    where
        Debug.EvaluatorM report = ctx ^. scDebugMonitors . Debug.sugaring . Debug.mAction

local :: (Context m -> Context m) -> ConvertM m a -> ConvertM m a
local f (ConvertM act) = ConvertM $ Reader.local f act

convertSubexpression ::
    (Monad m, Monoid a) => Val (Input.Payload m a) -> ConvertM m (ExpressionU m a)
convertSubexpression exprI =
    do
        convertSub <- Lens.view (Lens.to scConvertSubexpression)
        convertSub exprI
