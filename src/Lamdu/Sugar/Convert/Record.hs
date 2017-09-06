{-# LANGUAGE NoImplicitPrelude #-}
module Lamdu.Sugar.Convert.Record
    ( convertEmpty, convertExtend
    ) where

import qualified Control.Lens as Lens
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction)
import qualified Data.Store.Transaction as Transaction
import qualified Lamdu.Calc.Val as V
import qualified Lamdu.Calc.Val.Annotated as Val
import           Lamdu.Calc.Val.Annotated (Val(..))
import           Lamdu.Data.Anchors (assocTagOrder)
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Expr.IRef as ExprIRef
import           Lamdu.Sugar.Convert.Composite (convertCompositeItem)
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import           Lamdu.Sugar.Internal
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

plValI :: Lens.Lens' (Input.Payload m a) (ExprIRef.ValI m)
plValI = Input.stored . Property.pVal

makeAddField :: Monad m =>
    ExprIRef.ValIProperty m ->
    ConvertM m (Transaction m RecordAddFieldResult)
makeAddField stored =
    do
        protectedSetToVal <- ConvertM.typeProtectedSetToVal
        do
            DataOps.RecExtendResult tag newValI resultI <-
                DataOps.recExtend (stored ^. Property.pVal)
            _ <- protectedSetToVal stored resultI
            let resultEntity = EntityId.ofValI resultI
            return
                RecordAddFieldResult
                { _rafrNewTag = TagInfo (EntityId.ofRecExtendTag resultEntity) tag
                , _rafrNewVal = EntityId.ofValI newValI
                , _rafrRecExtend = resultEntity
                }
            & return

convertEmpty :: Monad m => Input.Payload m a -> ConvertM m (ExpressionU m a)
convertEmpty exprPl = do
    addField <- exprPl ^. Input.stored & makeAddField
    postProcess <- ConvertM.postProcess
    BodyRecord Record
        { _rItems = []
        , _rTail =
                DataOps.replaceWithHole (exprPl ^. Input.stored)
                <* postProcess
                <&> EntityId.ofValI
                & ClosedRecord
        , _rAddField = addField
        }
        & addActions exprPl

setTagOrder ::
    Monad m => Int -> RecordAddFieldResult -> Transaction m RecordAddFieldResult
setTagOrder i r =
    do
        Transaction.setP (assocTagOrder (r ^. rafrNewTag . tagVal)) i
        return r

convertExtend ::
    (Monad m, Monoid a) => V.RecExtend (Val (Input.Payload m a)) ->
    Input.Payload m a -> ConvertM m (ExpressionU m a)
convertExtend (V.RecExtend tag val rest) exprPl = do
    restS <- ConvertM.convertSubexpression rest
    restRecord <-
        case restS ^. rBody of
        BodyRecord r -> return r
        _ ->
            do
                addField <- rest ^. Val.payload . Input.stored & makeAddField
                Record [] (RecordExtending restS) addField & return
    fieldS <-
        convertCompositeItem
        (exprPl ^. Input.stored) (rest ^. Val.payload . plValI)
        (EntityId.ofRecExtendTag (exprPl ^. Input.entityId)) tag val
    restRecord
        & rItems %~ (fieldS:)
        & rAddField %~ (>>= setTagOrder (1 + length (restRecord ^. rItems)))
        & BodyRecord
        & addActions exprPl
