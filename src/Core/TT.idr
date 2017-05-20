module Core.TT

import Data.List
import Pruviloj.Derive.DecEq
import Language.Reflection

%default total

%language ElabReflection

public export
data Name = UN String
          | MN String Int
          | NS (List String) Name

decEqName : (x : Name) -> (y : Name) -> Dec (x = y)
%runElab (deriveDecEq `{decEqName})

export
DecEq Name where
  decEq = decEqName

%hide Raw -- from Reflection in the Prelude
%hide Binder
%hide NameType
%hide Case


export
Eq Name where
  (==) (UN x) (UN y) = x == y
  (==) (MN x y) (MN x' y') = x == x' && y == y'
  (==) (NS xs x) (NS xs' x') = xs == xs' && x == x'
  (==) _ _ = False


export
Ord Name where
  compare (UN _) (MN _ _) = LT
  compare (UN _) (NS _ _) = LT
  compare (MN _ _) (NS _ _) = LT

  compare (MN _ _) (UN _) = GT
  compare (NS _ _) (UN _) = GT
  compare (NS _ _) (MN _ _) = GT

  compare (UN x) (UN y) = compare x y
  compare (MN x y) (MN x' y') = case compare x x' of
                                     EQ => compare y y'
                                     t => t
  compare (NS x y) (NS x' y') = case compare x x' of
                                     EQ => compare y y'
                                     t => t

public export
data NameType : Type where
     Bound   : NameType
     Func    : NameType
     DataCon : (tag : Int) -> (arity : Nat) -> NameType
     TyCon   : (tag : Int) -> (arity : Nat) -> NameType

public export
data Constant = I Int
              | IntType

export
Eq Constant where
   (I x) == (I y) = x == y
   IntType == IntType = True
   _ == _ = False

public export
data PiInfo = Implicit | Explicit | AutoImplicit | Constraint

public export
data Binder : Type -> Type where
     Lam : (ty : type) -> Binder type
     Let : (val : type) -> (ty : type) -> Binder type
     Pi : PiInfo -> (ty : type) -> Binder type

export
Functor Binder where
  map func (Lam ty) = Lam (func ty)
  map func (Let val ty) = Let (func val) (func ty)
  map func (Pi x ty) = Pi x (func ty)

namespace ArgList
  data ArgList : (tm : List Name -> Type) ->
                 List Name -> Type where
       Nil : ArgList tm []
       (::) : tm vars -> ArgList tm ns -> ArgList tm (n :: ns)

-- Typechecked terms
-- These are guaranteed to be well-scoped wrt local variables, because they are
-- indexed by the names of local variables in scope
public export
data Term : List Name -> Type where
     Local : Elem x vars -> Term vars
     Ref : NameType -> (fn : Name) -> Term vars
     Bind : (x : Name) -> Binder (Term vars) -> 
                          Term (x :: vars) -> Term vars
     App : Term vars -> Term vars -> Term vars
     PrimVal : Constant -> Term vars
     Erased : Term vars
     TType : Term vars

-- TMP HACK!
Show (Term vars) where
  show (Local y) = "V"
  show (Ref x fn) = "Ref"
  show (Bind x y z) = "Bind"
  show (App x y) = "(" ++ show x ++ ", " ++ show y ++ ")"
  show (PrimVal x) = "Prim"
  show Erased = "[__]"
  show TType = "Type"

export
tm_id : Term []
tm_id = Bind (UN "ty") (Lam TType) $
        Bind (UN "x") (Lam (Local {x = UN "ty"} Here)) $
        Local {x = UN "x"} Here

%name TT.Binder b, b' 
%name TT.Term tm 

public export
ClosedTerm : Type
ClosedTerm = Term []

-- Environment containing types and values of local variables
namespace Env
  public export
  data Env : (tm : List Name -> Type) -> List Name -> Type where
       Nil : Env tm []
       (::) : Binder (tm vars) -> Env tm vars -> Env tm (x :: vars)

%name Env env

{- Some ugly mangling to allow us to extend the scope of a term - a
   term is always valid in a bigger scope than it needs. -}
insertElem : Elem x (outer ++ inner) -> Elem x (outer ++ n :: inner)
insertElem {outer = []} p = There p
insertElem {outer = (x :: xs)} Here = Here
insertElem {outer = (y :: xs)} (There later) 
   = There (insertElem {outer = xs} later)

thin : (n : Name) -> Term (outer ++ inner) -> Term (outer ++ n :: inner)
thin n (Local prf) = Local (insertElem prf)
thin n (Ref x fn) = Ref x fn
thin {outer} {inner} n (Bind x b sc) 
   = let sc' = thin {outer = x :: outer} {inner} n sc in
         assert_total $ Bind x (map (thin n) b) sc'
thin n (App f a) = App (thin n f) (thin n a)
thin n (PrimVal x) = PrimVal x
thin n Erased = Erased
thin n TType = TType

export
sameVar : Elem x xs -> Elem y xs -> Bool
sameVar Here Here = True
sameVar (There x) (There y) = sameVar x y
sameVar _ _ = False

export
elemExtend : Elem x xs -> Elem x (xs ++ ys)
elemExtend Here = Here
elemExtend (There later) = There (elemExtend later)

export
embed : Term vars -> Term (vars ++ more)
embed (Local prf) = Local (elemExtend prf)
embed (Ref x fn) = Ref x fn
embed (Bind x b tm) = Bind x (assert_total (map embed b)) (embed tm)
embed (App f a) = App (embed f) (embed a)
embed (PrimVal x) = PrimVal x
embed Erased = Erased
embed TType = TType

export
rename : (new : Name) -> Term (old :: vars) -> Term (new :: vars)

public export
interface Weaken (tm : List Name -> Type) where
  weaken : tm vars -> tm (n :: vars)

export
Weaken Term where
  weaken tm = thin {outer = []} _ tm

export
weakenBinder : Weaken tm => Binder (tm vars) -> Binder (tm (n :: vars))
weakenBinder = map weaken

export
getBinder : Weaken tm => Elem x vars -> Env tm vars -> Binder (tm vars)
getBinder Here (b :: env) = map weaken b
getBinder (There later) (b :: env) = map weaken (getBinder later env)

-- Some syntax manipulation

addVar : Elem var (later ++ vars) -> Elem var (later ++ x :: vars)
addVar {later = []} prf = There prf
addVar {later = (var :: xs)} Here = Here
addVar {later = (y :: xs)} (There prf) = There (addVar prf)

newLocal : Elem fn (later ++ fn :: vars)
newLocal {later = []} = Here
newLocal {later = (x :: xs)} = There newLocal

export
refToLocal : (x : Name) -> Term vars -> Term (x :: vars)
refToLocal x tm = mkLocal {later = []} x Here tm
  where
    mkLocal : (x : Name) -> 
              Elem x (later ++ x :: vars) ->
              Term (later ++ vars) -> Term (later ++ x :: vars)
    mkLocal x loc (Local prf) = Local (addVar prf)
    mkLocal x loc (Ref y fn) with (decEq x fn)
      mkLocal fn loc (Ref y fn) | (Yes Refl) = Local loc
      mkLocal x loc (Ref y fn) | (No contra) = Ref y fn
    mkLocal {later} x loc (Bind y b tm) 
        = Bind y (assert_total (map (mkLocal x loc) b)) 
                 (mkLocal {later = y :: later} x (There loc) tm)
    mkLocal x loc (App f a) = App (mkLocal x loc f) (mkLocal x loc a)
    mkLocal x loc (PrimVal y) = PrimVal y
    mkLocal x loc Erased = Erased
    mkLocal x loc TType = TType

export
apply : Term vars -> List (Term vars) -> Term vars
apply fn [] = fn
apply fn (arg :: args) = apply (App fn arg) args


-- Raw terms, not yet typechecked
public export
data Raw : Type where
     RVar : Name -> Raw
     RBind : Name -> Binder Raw -> Raw -> Raw
     RApp : Raw -> Raw -> Raw
     RPrimVal : Constant -> Raw
     RType : Raw


