{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Data.Infer
  ( Infer, Error(..)
  , infer, unify
  , emptyContext
  -- Re-export:
  , Context
  , TypedValue(..), tvVal, tvType
  , ScopedTypedValue(..), stvTV, stvScope
  ) where

import Control.Applicative (Applicative(..), (<*>), (<$>))
import Control.Lens.Operators
import Control.Monad (void)
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.Trans.State (StateT)
import Control.MonadA (MonadA)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Monoid (Monoid(..))
import Data.Store.Guid (Guid)
import Data.Traversable (sequenceA)
import Data.UnionFind (Ref)
import Lamdu.Data.Infer.Internal
import qualified Control.Lens as Lens
import qualified Data.Map as Map
import qualified Data.UnionFind as UF
import qualified Lamdu.Data.Expression as Expr
import qualified Lamdu.Data.Expression.Lens as ExprLens
import qualified Lamdu.Data.Expression.Utils as ExprUtil
import qualified Lamdu.Data.Infer.ExprRefs as ExprRefs

emptyContext :: Context def
emptyContext =
  Context
  { _ctxExprRefs =
    ExprRefs
    { _exprRefsUF = UF.empty
    , _exprRefsData = mempty
    }
  , _ctxDefRefs = Map.empty
  }

rename :: Map Guid Guid -> Guid -> Guid
rename renames guid = fromMaybe guid $ renames ^. Lens.at guid

data Error def
  = VarEscapesScope
  | VarNotInScope
  | Mismatch (Expr.Body def Ref) (Expr.Body def Ref)
  deriving (Show)

type Infer def = StateT (Context def) (Either (Error def))

-- If we don't assert that the scopes have same refs we could be pure
intersectScopes :: Map Guid Guid -> Scope -> Scope -> Infer def Scope
intersectScopes renames (Scope aScope) (Scope rawBScope) =
  Scope <$> sequenceA (Map.intersectionWith verifyEquiv aScope bScope)
  where
    bScope = Map.mapKeys (rename renames) rawBScope
    -- Expensive assertion
    verifyEquiv aref bref = do
      equiv <- ExprRefs.equiv aref bref
      if equiv
        then return aref
        else error "Scope unification of differing refs"

mergeBodies ::
  Eq def =>
  Map Guid Guid ->
  Expr.Body def Ref ->
  Expr.Body def Ref ->
  Infer def (Expr.Body def Ref)
mergeBodies _ a (Expr.BodyLeaf Expr.Hole) = return a
mergeBodies renames (Expr.BodyLeaf Expr.Hole) b =
  b & ExprLens.bodyParameterRef %~ rename renames & return
mergeBodies renames a b = do
  case sequenceA <$> ExprUtil.matchBody matchLamResult matchOther matchGetPar a b of
    Nothing -> lift . Left $ Mismatch a b
    Just mkBody -> mkBody
  where
    matchLamResult aGuid bGuid aRef bRef = do
      unifyRename (renames & Lens.at bGuid .~ Just aGuid) aRef bRef
    matchOther = unifyRename renames
    matchGetPar aGuid bGuid = aGuid == rename renames bGuid

mergeRefData :: Eq def => Map Guid Guid -> RefData def -> RefData def -> Infer def (RefData def)
mergeRefData renames (RefData aScope aBody) (RefData bScope bBody) =
  RefData
  <$> intersectScopes renames aScope bScope
  <*> mergeBodies renames aBody bBody

unifyRename :: Eq def => Map Guid Guid -> Ref -> Ref -> Infer def Ref
unifyRename = ExprRefs.unifyRefs . mergeRefData

unify :: Eq def => Ref -> Ref -> Infer def ()
unify x y = void $ unifyRename Map.empty x y

infer ::
  Scope -> Expr.Expression (LoadedDef def) a ->
  Infer def (Expr.Expression (LoadedDef def) (ScopedTypedValue, a))
infer = exprIntoSTV

makeHoleRef :: MonadA m => Scope -> StateT (Context def) m Ref
makeHoleRef scope =
  ExprRefs.fresh . RefData scope $ ExprLens.bodyHole # ()

scopeLookup :: Scope -> Guid -> Either (Error def) Ref
scopeLookup scope guid =
  case scope ^. scopeMap . Lens.at guid of
  Nothing -> Left VarNotInScope
  Just ref -> pure ref

makePiType ::
  MonadA m =>
  Scope -> Guid ->
  Expr.Expression defb (ScopedTypedValue, a) ->
  Expr.Expression defb (ScopedTypedValue, a) ->
  StateT (Context defa) m Ref
makePiType scope paramGuid paramType body =
  ExprRefs.fresh . RefData scope . Expr.BodyLam .
  Expr.Lam Expr.KType paramGuid (paramType ^. Expr.ePayload . Lens._1 . stvTV . tvVal) =<<
  makeHoleRef (body ^. Expr.ePayload . Lens._1 . stvScope)

makeRecordType ::
  MonadA m =>
  Scope ->
  [(Expr.Expression defb (ScopedTypedValue, a), t)] ->
  StateT (Context defa) m Ref
makeRecordType scope fields =
  fields
  & Lens.traverse %%~ onField
  >>= ExprRefs.fresh . RefData scope .
      Expr.BodyRecord . Expr.Record Expr.KType
  where
    onField (tag, _) =
      (,) (tag ^. Expr.ePayload . Lens._1 . stvTV . tvVal)
      <$> makeHoleRef scope

makeTypeRef ::
  Scope ->
  Expr.Body (LoadedDef def) (Expr.Expression (LoadedDef def) (ScopedTypedValue, a)) ->
  Infer def Ref
makeTypeRef scope body =
  case body of
  -- Simple types
  Expr.BodyLeaf Expr.Type -> typeIsType
  Expr.BodyLeaf Expr.IntegerType -> typeIsType
  Expr.BodyLeaf Expr.TagType -> typeIsType
  Expr.BodyLam (Expr.Lam Expr.KType _ _ _) -> typeIsType
  Expr.BodyRecord (Expr.Record Expr.KType _) -> typeIsType
  Expr.BodyLeaf Expr.LiteralInteger {} -> resNoScope $ ExprLens.bodyIntegerType # ()
  -- Unknown
  Expr.BodyApply {} -> makeHoleRef scope
  Expr.BodyGetField {} -> makeHoleRef scope
  Expr.BodyLeaf Expr.Hole -> makeHoleRef scope
  -- GetPars
  Expr.BodyLeaf (Expr.GetVariable (Expr.DefinitionRef (LoadedDef _ ref))) -> pure ref
  Expr.BodyLeaf (Expr.GetVariable (Expr.ParameterRef guid)) -> lift $ scopeLookup scope guid
  Expr.BodyLeaf Expr.Tag {} -> resNoScope $ ExprLens.bodyTagType # ()
  Expr.BodyLam (Expr.Lam Expr.KVal paramGuid paramType result) -> makePiType scope paramGuid paramType result
  Expr.BodyRecord (Expr.Record Expr.KVal fields) -> makeRecordType scope fields
  where
    typeIsType = resNoScope $ ExprLens.bodyType # ()
    resNoScope = ExprRefs.fresh . RefData mempty

-- With hole apply vals and hole types
exprIntoSTV ::
  Scope -> Expr.Expression (LoadedDef def) a ->
  Infer def (Expr.Expression (LoadedDef def) (ScopedTypedValue, a))
exprIntoSTV scope (Expr.Expression body pl) = do
  newBody <-
    case body of
    Expr.BodyLam (Expr.Lam k paramGuid paramType result) -> do
      paramTypeS <- exprIntoSTV scope paramType
      let
        newScope =
          scope
          & scopeMap . Lens.at paramGuid .~
            Just (paramTypeS ^. Expr.ePayload . Lens._1 . stvTV . tvVal)
      resultS <- exprIntoSTV newScope result
      pure . Expr.BodyLam $ Expr.Lam k paramGuid paramTypeS resultS
    _ ->
      body & Lens.traverse %%~ exprIntoSTV scope
  valRef <-
    newBody
    <&> (^. Expr.ePayload . Lens._1 . stvTV . tvVal)
    & ExprLens.bodyDef %~ (^. ldDef)
    & circumcizeApply
    & RefData scope
    & ExprRefs.fresh
  typeRef <- makeTypeRef scope newBody
  pure $
    Expr.Expression newBody
    ((ScopedTypedValue (TypedValue valRef typeRef) scope), pl)
  where
    circumcizeApply Expr.BodyApply{} = ExprLens.bodyHole # ()
    circumcizeApply x = x
