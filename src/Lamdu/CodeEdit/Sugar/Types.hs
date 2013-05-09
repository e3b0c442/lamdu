{-# LANGUAGE KindSignatures, TemplateHaskell, DeriveFunctor, DeriveFoldable, DeriveTraversable, GeneralizedNewtypeDeriving, DeriveDataTypeable #-}
module Lamdu.CodeEdit.Sugar.Types
  ( Definition(..), drName, drGuid, drType, drBody
  , DefinitionBody(..)
  , ListItemActions(..), itemAddNext, itemDelete
  , FuncParamActions(..), fpListItemActions, fpGetExample
  , DefinitionExpression(..), deContent, deIsTypeRedundant, deMNewType
  , DefinitionContent(..)
  , DefinitionNewType(..)
  , DefinitionBuiltin(..)
  , Actions(..)
    , giveAsArg, callWithArg, callWithNextArg
    , setToHole, replaceWithNewHole, cut, giveAsArgToOperator
  , ExpressionBody(..), eHasParens
    , _ExpressionPi, _ExpressionApply, _ExpressionSection
    , _ExpressionFunc, _ExpressionGetVar, _ExpressionHole
    , _ExpressionInferred, _ExpressionCollapsed
    , _ExpressionLiteralInteger, _ExpressionAtom
    , _ExpressionList, _ExpressionRecord, _ExpressionTag
  , Payload(..), plInferredTypes, plActions, plNextHole
  , ExpressionP(..)
    , rGuid, rExpressionBody, rPayload, rHiddenGuids, rPresugaredExpression
  , NameSource(..), Name(..), NameHint
  , DefinitionN, DefinitionU
  , Expression, ExpressionN, ExpressionU
  , ExpressionBodyN, ExpressionBodyU
  , WhereItem(..)
  , ListItem(..), ListActions(..), List(..)
  , RecordField(..), rfMItemActions, rfTag, rfExpr
  , Kind(..)
  , Record(..), rKind, rFields
  , FieldList(..), flItems, flMAddFirstItem
  , GetField(..), gfRecord, gfTag
  , GetVar(..), VarType(..)
  , Func(..), fDepParams, fParams, fBody
  , FuncParam(..), fpName, fpGuid, fpHiddenLambdaGuid, fpType, fpMActions
  , TagG(..), tagName, tagGuid
  , Pi(..)
  , Section(..)
  , ScopeItem(..), _ScopeVar, _ScopeTag
  , Hole(..), holeScope, holeMActions
  , HoleResultSeed(..)
  , HoleActions(..)
    , holePaste, holeMDelete, holeResult, holeInferExprType
  , StorePoint(..)
  , HoleResult(..)
    , holeResultInferred
    , holeResultConverted
    , holeResultPick, holeResultPickPrefix
  , LiteralInteger(..)
  , Inferred(..), iValue, iHole
  , Collapsed(..), pFuncGuid, pCompact, pFullExpression
  , HasParens(..)
  , T, CT
  , PrefixAction, emptyPrefixAction
  ) where

import Control.Monad.Trans.State (StateT)
import Data.Binary (Binary)
import Data.Cache (Cache)
import Data.Foldable (Foldable)
import Data.Store.Guid (Guid)
import Data.Store.IRef (Tag)
import Data.Store.Transaction (Transaction)
import Data.Traversable (Traversable)
import Data.Typeable (Typeable)
import Lamdu.Data.Expression (Kind(..))
import Lamdu.Data.Expression.IRef (DefI)
import qualified Control.Lens.TH as LensTH
import qualified Data.List as List
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Data.Expression as Expression
import qualified Lamdu.Data.Expression.IRef as DataIRef
import qualified Lamdu.Data.Expression.Infer as Infer

type T = Transaction
type CT m = StateT Cache (T m)

type PrefixAction m = T m ()

emptyPrefixAction :: Monad m => PrefixAction m
emptyPrefixAction = return ()

data Actions m = Actions
  { _giveAsArg :: PrefixAction m -> T m Guid
  -- Turn "x" to "x ? _" where "?" is an operator-hole.
  -- Given string is initial hole search term.
  , _giveAsArgToOperator :: T m Guid
  , _callWithNextArg :: PrefixAction m -> CT m (Maybe (T m Guid))
  , _callWithArg :: PrefixAction m -> CT m (Maybe (T m Guid))
  , _setToHole :: T m Guid
  , _replaceWithNewHole :: T m Guid
  , _cut :: T m Guid
  }
LensTH.makeLenses ''Actions

data HasParens = HaveParens | DontHaveParens

data Payload name m = Payload
  { _plInferredTypes :: [Expression name m]
  , _plActions :: Maybe (Actions m)
  , _plNextHole :: Maybe (Expression name m)
  }

newtype StorePoint t = StorePoint { unStorePoint :: DataIRef.ExpressionI t }
  deriving (Eq, Binary, Typeable)

data ExpressionP name m pl = Expression
  { _rGuid :: Guid
  , _rExpressionBody :: ExpressionBody name m (ExpressionP name m pl)
  , _rPayload :: pl
  , -- Guids from data model expression which were sugared out into
    -- this sugar expression.
    -- If the cursor was on them for whatever reason, it should be
    -- mapped into the sugar expression's guid.
    _rHiddenGuids :: [Guid]
  , _rPresugaredExpression :: DataIRef.ExpressionM m (Maybe (StorePoint (Tag m)))
  } deriving (Functor, Foldable, Traversable)

data NameSource = AutoGeneratedName | StoredName
  deriving (Show)
data Name = Name
  { nNameSource :: NameSource
  , nName :: String
  } deriving (Show)
type NameHint = Maybe String

type Expression name m = ExpressionP name m (Payload name m)
type ExpressionN m = Expression Name m
type ExpressionU m = Expression NameHint m

type ExpressionBodyN m = ExpressionBody Name m (ExpressionN m)
type ExpressionBodyU m = ExpressionBody NameHint m (ExpressionU m)

data ListItemActions m = ListItemActions
  { _itemAddNext :: T m Guid
  , _itemDelete :: T m Guid
  }

data FuncParamActions name m = FuncParamActions
  { _fpListItemActions :: ListItemActions m
  , _fpGetExample :: CT m (Expression name m)
  }

data FuncParam name m expr = FuncParam
  { _fpGuid :: Guid
  , _fpName :: name
  , _fpHiddenLambdaGuid :: Maybe Guid
  , _fpType :: expr
  , _fpMActions :: Maybe (FuncParamActions name m)
  } deriving (Functor, Foldable, Traversable)

-- Multi-param Lambda
data Func name m expr = Func
  { _fDepParams :: [FuncParam name m expr]
  , _fParams :: [FuncParam name m expr]
  , _fBody :: expr
  } deriving (Functor, Foldable, Traversable)

data Pi name m expr = Pi
  { pParam :: FuncParam name m expr
  , pResultType :: expr
  } deriving (Functor, Foldable, Traversable)

-- Infix Sections include: (+), (1+), (+1), (1+2). Last is really just
-- infix application, but considered an infix section too.
data Section expr = Section
  { sectionLArg :: Maybe expr
  , sectionOp :: expr -- TODO: Always a Data.GetVariable, use a more specific type
  , sectionRArg :: Maybe expr
  } deriving (Functor, Foldable, Traversable)

data HoleResult name m = HoleResult
  { _holeResultInferred :: DataIRef.ExpressionM m (Infer.Inferred (DefI (Tag m)))
  , _holeResultConverted :: Expression name m
  , _holeResultPick :: T m (Maybe Guid)
  , _holeResultPickPrefix :: PrefixAction m
  }

data ScopeItem name m
  = ScopeVar (GetVar name m)
  | ScopeTag (TagG name)

data HoleResultSeed m
  = ResultSeedExpression (DataIRef.ExpressionM m (Maybe (StorePoint (Tag m))))
  | ResultSeedNewTag String

data HoleActions name m = HoleActions
  { _holeScope :: T m [(ScopeItem name m, DataIRef.ExpressionM m ())]
  , -- Infer expression "on the side" (not in the hole position),
    -- but with the hole's scope in scope.
    -- If given expression does not type check on its own, returns Nothing.
    -- (used by HoleEdit to suggest variations based on type)
    _holeInferExprType :: DataIRef.ExpressionM m () -> CT m (Maybe (DataIRef.ExpressionM m ()))
  , _holeResult :: HoleResultSeed m -> CT m (Maybe (HoleResult name m))
  , _holePaste :: Maybe (T m Guid)
  , -- TODO: holeMDelete is always Nothing, not implemented yet
    _holeMDelete :: Maybe (T m Guid)
  }

newtype Hole name m = Hole
  { _holeMActions :: Maybe (HoleActions name m)
  }

data LiteralInteger m = LiteralInteger
  { liValue :: Integer
  , liSetValue :: Maybe (Integer -> T m ())
  }

data Inferred name m expr = Inferred
  { _iValue :: expr
  , _iHole :: Hole name m
  } deriving (Functor, Foldable, Traversable)

-- TODO: New name. This is not only for polymorphic but also for eta-reduces etc
data Collapsed name m expr = Collapsed
  { _pFuncGuid :: Guid
  , _pCompact :: GetVar name m
  , _pFullExpression :: expr
  } deriving (Functor, Foldable, Traversable)

-- TODO: Do we want to store/allow-access to the implicit type params (nil's type, each cons type?)
data ListItem m expr = ListItem
  { liMActions :: Maybe (ListItemActions m)
  , liExpr :: expr
  } deriving (Functor, Foldable, Traversable)

data ListActions m = ListActions
  { addFirstItem :: T m Guid
  , replaceNil :: T m Guid
  }

data List m expr = List
  { lValues :: [ListItem m expr]
  , lMActions :: Maybe (ListActions m)
  } deriving (Functor, Foldable, Traversable)

data RecordField m expr = RecordField
  { _rfMItemActions :: Maybe (ListItemActions m)
  , _rfTag :: expr
  , _rfExpr :: expr -- field type or val
  } deriving (Functor, Foldable, Traversable)

data FieldList m expr = FieldList
  { _flItems :: [RecordField m expr]
  , _flMAddFirstItem :: Maybe (T m Guid)
  } deriving (Functor, Foldable, Traversable)

data Record m expr = Record
  { _rKind :: Kind -- record type or val
  , _rFields :: FieldList m expr
  } deriving (Functor, Foldable, Traversable)

data GetField expr = GetField
  { _gfRecord :: expr
  , _gfTag :: expr
  } deriving (Functor, Foldable, Traversable)

data VarType = GetParameter | GetDefinition
  deriving (Eq, Ord)

data GetVar name m = GetVar
  { gvIdentifier :: Guid
  , gvName :: name
  , gvJumpTo :: T m Guid
  , gvVarType :: VarType
  }

data TagG name = TagG
  { _tagGuid :: Guid
  , _tagName :: name
  } deriving (Functor, Foldable, Traversable)

data ExpressionBody name m expr
  = ExpressionApply   { _eHasParens :: HasParens, __eApply :: Expression.Apply expr }
  | ExpressionSection { _eHasParens :: HasParens, __eSection :: Section expr }
  | ExpressionFunc    { _eHasParens :: HasParens, __eFunc :: Func name m expr }
  | ExpressionPi      { _eHasParens :: HasParens, __ePi :: Pi name m expr }
  | ExpressionHole    { __eHole :: Hole name m }
  | ExpressionInferred { __eInferred :: Inferred name m expr }
  | ExpressionCollapsed { __eCollapsed :: Collapsed name m expr }
  | ExpressionLiteralInteger { __eLit :: LiteralInteger m }
  | ExpressionAtom     { __eAtom :: String }
  | ExpressionList     { __eList :: List m expr }
  | ExpressionRecord   { __eRecord :: Record m expr }
  | ExpressionGetField { __eGetField :: GetField expr }
  | ExpressionTag      { __eTag :: TagG name }
  | ExpressionGetVar   { __eGetParam :: GetVar name m }
  deriving (Functor, Foldable, Traversable)

wrapParens :: HasParens -> String -> String
wrapParens HaveParens x = concat ["(", x, ")"]
wrapParens DontHaveParens x = x

instance Show expr => Show (FuncParam name m expr) where
  show fp =
    concat ["(", show (_fpGuid fp), ":", show (_fpType fp), ")"]

instance Show expr => Show (ExpressionBody name m expr) where
  show ExpressionApply   { _eHasParens = hasParens, __eApply = Expression.Apply func arg } =
    wrapParens hasParens $ show func ++ " " ++ show arg
  show ExpressionSection { _eHasParens = hasParens, __eSection = Section mleft op mright } =
    wrapParens hasParens $ maybe "" show mleft ++ " " ++ show op ++ maybe "" show mright
  show ExpressionFunc    { _eHasParens = hasParens, __eFunc = Func depParams params body } =
    wrapParens hasParens $ concat
    ["\\", parenify (showWords depParams), showWords params, " -> ", show body]
    where
      parenify "" = ""
      parenify xs = concat ["{", xs, "}"]
      showWords = unwords . map show
  show ExpressionPi      { _eHasParens = hasParens, __ePi = Pi paramType resultType } =
    wrapParens hasParens $ "_:" ++ show paramType ++ " -> " ++ show resultType
  show ExpressionHole {} = "Hole"
  show ExpressionInferred {} = "Inferred"
  show ExpressionCollapsed {} = "Collapsed"
  show ExpressionLiteralInteger { __eLit = LiteralInteger i _ } = show i
  show ExpressionAtom { __eAtom = atom } = atom
  show ExpressionList { __eList = List items _ } =
    concat
    [ "["
    , List.intercalate ", " $ map (show . liExpr) items
    , "]"
    ]
  show ExpressionRecord { __eRecord = _ } = "Record:TODO"
  show ExpressionGetField { __eGetField = _ } = "GetField:TODO"
  show ExpressionTag { __eTag = _ } = "Tag:TODO"
  show ExpressionGetVar {} = "GetVar:TODO"

data DefinitionNewType name m = DefinitionNewType
  { dntNewType :: Expression name m
  , dntAcceptNewType :: T m ()
  }

data WhereItem name m = WhereItem
  { wiValue :: DefinitionContent name m
  , wiGuid :: Guid
  , wiName :: name
  , wiHiddenGuids :: [Guid]
  , wiActions :: Maybe (ListItemActions m)
  }

-- Common data for definitions and where-items
data DefinitionContent name m = DefinitionContent
  { dDepParams :: [FuncParam name m (Expression name m)]
  , dParams :: Maybe (FuncParam name m (Expression name m))
  , dBody :: Expression name m
  , dWhereItems :: [WhereItem name m]
  , dAddFirstParam :: T m Guid
  , dAddInnermostWhereItem :: T m Guid
  }

data DefinitionExpression name m = DefinitionExpression
  { _deContent :: DefinitionContent name m
  , _deIsTypeRedundant :: Bool
  , _deMNewType :: Maybe (DefinitionNewType name m)
  }

data DefinitionBuiltin m = DefinitionBuiltin
  { biName :: Definition.FFIName
  -- Consider removing Maybe'ness here
  , biMSetName :: Maybe (Definition.FFIName -> T m ())
  }

data DefinitionBody name m
  = DefinitionBodyExpression (DefinitionExpression name m)
  | DefinitionBodyBuiltin (DefinitionBuiltin m)

data Definition name m = Definition
  { _drGuid :: Guid
  , _drName :: name
  , _drType :: Expression name m
  , _drBody :: DefinitionBody name m
  }

type DefinitionN = Definition Name
type DefinitionU = Definition NameHint

LensTH.makePrisms ''ScopeItem
LensTH.makePrisms ''ExpressionBody
LensTH.makeLenses ''Definition
LensTH.makeLenses ''DefinitionExpression
LensTH.makeLenses ''Inferred
LensTH.makeLenses ''Collapsed
LensTH.makeLenses ''Func
LensTH.makeLenses ''FuncParam
LensTH.makeLenses ''RecordField
LensTH.makeLenses ''FieldList
LensTH.makeLenses ''Record
LensTH.makeLenses ''GetField
LensTH.makeLenses ''TagG
LensTH.makeLenses ''ExpressionBody
LensTH.makeLenses ''ListItemActions
LensTH.makeLenses ''FuncParamActions
LensTH.makeLenses ''Payload
LensTH.makeLenses ''ExpressionP
LensTH.makeLenses ''HoleResult
LensTH.makeLenses ''HoleActions
LensTH.makeLenses ''Hole
