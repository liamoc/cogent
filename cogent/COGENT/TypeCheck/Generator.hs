--
-- Copyright 2016, NICTA
--
-- This software may be distributed and modified according to the terms of
-- the GNU General Public License version 2. Note that NO WARRANTY is provided.
-- See "LICENSE_GPLv2.txt" for details.
--
-- @TAG(NICTA_GPL)
--

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

module COGENT.TypeCheck.Generator
  ( runCG
  , CG
  , cg
  , cgAlts
  ) where

import           COGENT.Common.Syntax
import           COGENT.Common.Types
import           COGENT.Surface
import           COGENT.Util hiding (Warning)
import           COGENT.TypeCheck.Base
import qualified COGENT.Context as C

import           Control.Arrow (first, second)
import           Control.Lens hiding (Context, (:<))
import           Control.Monad.State
import qualified Data.Map as M
import           Data.Maybe (catMaybes, isNothing, isJust)
import           Data.Monoid ((<>))
import           Text.Parsec.Pos

-- import Debug.Trace
-- import COGENT.PrettyPrint()
-- import Text.PrettyPrint.ANSI.Leijen (Pretty (..))
data CGState = CGS { _tc :: TCState, _context :: C.Context TCType, _flexes :: Int, _knownTypeVars :: [VarName] }

makeLenses ''CGState

type CG x = State CGState x

runCG :: C.Context TCType -> [VarName] -> CG a -> TC (a, Int)
runCG g vs a = do
  x <- get
  let (r, CGS x' _ f _) = runState a (CGS x g 0 vs)
  put x'
  return (r,f)

fresh :: CG TCType
fresh = U <$> (flexes <<%= succ)

cg :: LocExpr -> TCType -> CG (Constraint, TCExpr)
cg x@(LocExpr l e) t = do
  let ?loc = l
  (c, e') <- cg' e t
  return (c :@ InExpression x t, TE t e' l)

cgMany :: (?loc :: SourcePos) => [LocExpr] -> CG ([TCType], Constraint, [TCExpr])
cgMany es = do
  let each (ts,c,es') e = do
        alpha    <- fresh
        (c', e') <- cg e alpha
        return (alpha:ts, c' <> c, e':es')
  (ts, c', es') <- foldM each ([], Sat, []) es
  return (reverse ts, c', reverse es')

cg' :: (?loc :: SourcePos) => Expr LocType VarName LocExpr -> TCType -> CG (Constraint, Expr TCType TCTypedName TCExpr)
cg' (PrimOp o [e1, e2]) t
  | o `elem` words "+ - * / % .&. .|. .^. >> <<"
  = do (c1, e1') <- cg e1 t
       (c2, e2') <- cg e2 t
       -- traceShowM ("Arith op", pretty (stripLocE e1), pretty (stripLocE e2), pretty t, pretty c1, pretty c2)
       return (T (TCon "U8" [] Unboxed) :<~ t <> c1 <> c2, PrimOp o [e1', e2'] )
  | o `elem` words "&& ||"
  = do (c1, e1') <- cg e1 t
       (c2, e2') <- cg e2 t
       return (T (TCon "Bool" [] Unboxed) :< t <> c1 <> c2, PrimOp o [e1', e2'] )
  | o `elem` words "== /= >= <= > <"
  = do alpha <- fresh
       (c1, e1') <- cg e1 alpha
       (c2, e2') <- cg e2 alpha
       let c  = T (TCon "Bool" [] Unboxed) :< t
           c' = T (TCon "U8" [] Unboxed) :<~ alpha
       return (c <> c' <> c1 <> c2, PrimOp o [e1', e2'] )
cg' (PrimOp o [e]) t
  | o == "complement"  = do
      (c, e') <- cg e t
      return (T (TCon "U8" [] Unboxed) :<~ t :& c, PrimOp o [e'])
  | o == "not"         = do
      (c, e') <- cg e t
      return (T (TCon "Bool" [] Unboxed) :< t :& c, PrimOp o [e'])
cg' (PrimOp o _) t = error "impossible"
cg' (Var n) t = do
  ctx <- use context

  let e = Var n
  case C.lookup n ctx of
    -- Variable not found, see if the user meant a function.
    Nothing ->
      use (tc.knownFuns.at n) >>= \case
        Just _  -> cg' (TypeApp n [] NoInline) t
        Nothing -> return (Unsat (NotInScope n), e)

    -- Variable used for the first time, mark the use, and continue
    Just (t', p, Nothing) -> do
      context %= C.use n ?loc
      return (t' :< t, e)

    -- Variable already used before, emit a Share constraint.
    Just (t', p, Just l)  ->
      return (Share t' (Reused n p l) <> t' :< t, e)

cg' (Upcast e) t = do
  alpha <- fresh
  (c1, e1') <- cg e alpha
  let c = (T (TCon "U8" [] Unboxed) :<~ alpha) <> alpha :<~ t <> c1
  return (c, Upcast e1')

cg' (Widen e) t = do
  alpha <- fresh
  (c1, e1') <- cg e alpha
  let c = (T (TVariant M.empty) :<~ alpha) <> (alpha :<~ t) <> c1
  return (c, Upcast e1')

cg' (BoolLit b) t = do
  let c = T (TCon "Bool" [] Unboxed) :< t
      e = BoolLit b
  return (c,e)

cg' (CharLit l) t = do
  let c = T (TCon "U8" [] Unboxed) :< t
      e = CharLit l
  return (c,e)

cg' (StringLit l) t = do
  let c = T (TCon "String" [] Unboxed) :< t
      e = StringLit l
  return (c,e)

cg' Unitel t = do
  let c = T TUnit :< t
      e = Unitel
  return (c,e)

cg' (IntLit i) t = do
  let minimumBitwidth | i < 256        = "U8"
                      | i < 65536      = "U16"
                      | i < 4294967296 = "U32"
                      | otherwise      = "U64"
      c = T (TCon minimumBitwidth [] Unboxed) :<~ t
      e = IntLit i
  return (c,e)

cg' (App e1 e2) t = do
  alpha     <- fresh
  (c1, e1') <- cg e1 (T (TFun alpha t))
  (c2, e2') <- cg e2 alpha

  let c = c1 <> c2
      e = App e1' e2'
  return (c,e)

cg' (Con k es) t = do
  (ts, c', es') <- cgMany es

  let e = Con k es'
      c = c' <> T (TVariant (M.fromList [(k, ts)])) :<~ t
  return (c,e)

cg' (Tuple es) t = do
  (ts, c', es') <- cgMany es

  let e = Tuple es'
      c = c' <> T (TTuple ts) :< t
  return (c,e)

cg' (UnboxedRecord fes) t = do
  let (fs, es) = unzip fes
  (ts, c', es') <- cgMany es

  let e = UnboxedRecord (zip fs es')
      r = T (TRecord (zip fs (map (, False) ts)) Unboxed)
      c = c' <> r :< t
  -- traceShowM ("Checking UnboxedRecord", pretty c)
  return (c,e)

cg' (Seq e1 e2) t = do
  alpha <- fresh
  (c1, e1') <- cg e1 alpha
  (c2, e2') <- cg e2 t

  let e = Seq e1' e2'
      c = c1 <> Drop alpha Suppressed <> c2
  return (c, e)

cg' (TypeApp f as i) t = do
  tvs <- use knownTypeVars
  (c,as') <- zoom tc (validateTypes' tvs (map stripLocT as)) >>= \case
    Left e -> return (Unsat e, [])
    Right as -> return (Sat, as)
  use (tc.knownFuns.at f) >>= \case

    Just (PT vs tau) -> let
        match [] []     = return ([], Sat)
        match [] (a:as) = return ([], Unsat (TooManyTypeArguments f (PT vs tau)))
        match vs []     = fresh >>= match vs . return
        match ((v, k):vs) (a:as) = do
          (ts, c) <- match vs as
          return ((v,a):ts, kindToConstraint k a (TypeParam f v) <> c)
      in do
        (ts,c') <- match vs as'

        let c = c' <> substType ts tau :< t
            e = TypeApp f (map snd ts) i
        return (c, e)

    Nothing -> do
      let e = TypeApp f as' i
          c = Unsat (FunctionNotFound f)
      return (c, e)

cg' (Member e f) t = do
  alpha <- fresh
  (c', e') <- cg e alpha

  let e = Member e' f
      x = T (TRecord [(f, (t, False))] Unboxed)
      c = c' <> x :<~ alpha <> Share alpha (UsedInMember f)
  return (c, e)

cg' (If e1 bs e2 e3) t = do
  (c1, e1') <- letBang bs (cg e1) (T (TCon "Bool" [] Unboxed))
  (c, [(c2, e2'), (c3, e3')]) <- parallel' [(ThenBranch, cg e2 t), (ElseBranch, cg e3 t)]
  return (c1 <> c <> c2 <> c3, If e1' bs e2' e3')

cg' (Put e ls) t | not (any isNothing ls) = do
  alpha <- fresh
  let (fs, es) = unzip (catMaybes ls)
  (c', e') <- cg e alpha -- (T (TTake (Just fs) t))
  (ts, cs, es') <- cgMany es

  let c = (T (TPut (Just fs) alpha)) :< t <> c' <> cs
       <> (T (TRecord (zip fs (map (,True) ts)) Unboxed) :<~ alpha)
      e = Put e' (map Just (zip fs es'))
  return (c,e)

  | otherwise = first (<> Unsat RecordWildcardsNotSupported) <$> cg' (Put e (filter isJust ls)) t

cg' (Let bs e) t = do
  (c, bs', (c', e')) <- withBindings bs (cg e t)
  return (c <> c', Let bs' e')

cg' (Match e bs alts) top = do
  alpha <- fresh
  (c', e') <- letBang bs (cg e) alpha
  (c'', alts') <- cgAlts alts top alpha

  let c = c' :& c''
      e = Match e' bs alts'
  return (c, e)


cgAlts :: (?loc :: SourcePos) => [Alt VarName LocExpr] -> TCType -> TCType -> CG (Constraint, [Alt TCTypedName TCExpr])
cgAlts alts top alpha = do
  let
    altPattern (Alt p _ _) = p

    f (Alt p like e) t = do
      (s, c, p') <- matchA p t
      context %= C.addScope s
      (c', e') <- cg e top
      context %= C.dropScope
      return (RemoveCase p' t, (c <> c', Alt p' like e'))

    jobs = map (\(n, alt) -> (NthAlternative n (altPattern alt), f alt)) (zip [1..] alts)

  (c'', blob) <- parallel jobs alpha

  let (cs, alts') = unzip blob
      c = mconcat (Exhaustive alpha (map altPattern alts'):c'':cs)
  return (c, alts')

matchA :: (?loc :: SourcePos)
       => Pattern VarName -> TCType
       -> CG (M.Map VarName (C.Row TCType), Constraint, Pattern TCTypedName)

matchA (PIrrefutable i) t = do
  (s, c, i') <- match i t
  return (s, c, PIrrefutable i')

matchA (PCon k is) t = do
  (vs, blob) <- unzip <$> forM is (\i -> do alpha <- fresh; (alpha,) <$> match i alpha)
  let (ss, cs, is') = (map fst3 blob, map snd3 blob, map thd3 blob)
      p' = PCon k is'
      co = case overlapping ss of
             Left (v:vs) -> Unsat $ DuplicateVariableInPattern v p'
             _           -> Sat

  return (M.unions ss, co <> mconcat cs <> T (TVariant (M.fromList [(k, vs)])) :<~ t, p')

matchA (PIntLit i) t = do
  let minimumBitwidth | i < 256        = "U8"
                      | i < 65536      = "U16"
                      | i < 4294967296 = "U32"
                      | otherwise      = "U64"
      c = T (TCon minimumBitwidth [] Unboxed) :<~ t
  return (M.empty, c, PIntLit i)

matchA (PBoolLit b) t =
  return (M.empty, T (TCon "Bool" [] Unboxed) :< t, PBoolLit b)

matchA (PCharLit c) t =
  return (M.empty, T (TCon "U8" [] Unboxed) :< t, PCharLit c)

match :: (?loc :: SourcePos)
      => IrrefutablePattern VarName -> TCType
      -> CG (M.Map VarName (C.Row TCType), Constraint, IrrefutablePattern TCTypedName)

match (PVar x) t = return (M.fromList [(x, (t,?loc,Nothing))], Sat, PVar (x,t))

match (PUnderscore) t = return (M.empty, Sat, PUnderscore)

match (PUnitel) t = return (M.empty, T TUnit :< t, PUnitel)

match (PTuple ps) t = do
   (vs, blob) <- unzip <$> mapM (\p -> do v <- fresh; (v,) <$> match p v) ps
   let (ss, cs, ps') = (map fst3 blob, map snd3 blob, map thd3 blob)
       p' = PTuple ps'
       co = case overlapping ss of
              Left (v:vs) -> Unsat $ DuplicateVariableInIrrefPattern v p'
              _           -> Sat
   return (M.unions ss, co <> mconcat cs <> T (TTuple vs) :< t, p')

match (PUnboxedRecord fs) t | not (any isNothing fs) = do
   let (ns, ps) = unzip (catMaybes fs)
   (vs, blob) <- unzip <$> mapM (\p -> do v <- fresh; (v,) <$> match p v) ps
   let (ss, cs, ps') = (map fst3 blob, map snd3 blob, map thd3 blob)
       t' = T (TRecord (zip ns (map (,False) vs)) Unboxed)
       d  = Drop (T (TTake (Just ns) t)) Suppressed
       p' = PUnboxedRecord (map Just (zip ns ps'))
       co = case overlapping ss of
              Left (v:vs) -> Unsat $ DuplicateVariableInIrrefPattern v p'
              _           -> Sat
   return (M.unions ss, co <> mconcat cs <> t' :<~ t <> d, p')

   | otherwise = second3 (:& Unsat RecordWildcardsNotSupported) <$> match (PUnboxedRecord (filter isJust fs)) t

match (PTake r fs) t | not (any isNothing fs) = do
   let (ns, ps) = unzip (catMaybes fs)
   (vs, blob) <- unzip <$> mapM (\p -> do v <- fresh; (v,) <$> match p v) ps
   let (ss, cs, ps') = (map fst3 blob, map snd3 blob, map thd3 blob)
       t' = T (TRecord (zip ns (map (,False) vs)) Unboxed)
       s  = M.fromList [(r, (u, ?loc, Nothing))]
       u  = T (TTake (Just ns) t)
       p' = PTake (r,u) (map Just (zip ns ps'))
       co = case overlapping (s:ss) of
              Left (v:vs) -> Unsat $ DuplicateVariableInIrrefPattern v p'
              _           -> Sat
   return (M.unions (s:ss), co <> mconcat cs <> t' :<~ t, p')

   | otherwise = second3 (:& Unsat RecordWildcardsNotSupported) <$> match (PTake r (filter isJust fs)) t

withBindings :: (?loc::SourcePos)
  => [Binding LocType VarName LocExpr]
  -> CG a -> CG (Constraint, [Binding TCType TCTypedName TCExpr], a)
withBindings [] a = (Sat, [],) <$> a
withBindings (Binding pat tau e bs : xs) a = do
  alpha <- fresh
  (c1, e') <- letBang bs (cg e) alpha
  ct <- case tau of
    Nothing -> return Sat
    Just tau' -> do
      tvs <- use knownTypeVars
      zoom tc (validateType' tvs (stripLocT tau')) >>= \case
        Left e -> return (Unsat e)
        Right t -> return (alpha :< t)
  (s, cp, pat') <- match pat alpha
  context %= C.addScope s
  (c', xs', r) <- withBindings xs a
  context %= C.dropScope

  let c = ct <> c1 <> c' <> cp
      b' = Binding pat' (Just alpha) e' bs
  return (c, b':xs', r)

parallel' :: [(ErrorContext, CG (Constraint, a))] -> CG (Constraint, [(Constraint, a)])
parallel' ls = parallel (map (second (\a _ -> ((), ) <$> a)) ls) ()

parallel :: [(ErrorContext, acc -> CG (acc, (Constraint, a)))] -> acc -> CG (Constraint, [(Constraint, a)])
parallel []       acc = return (Sat, [])
parallel [(ct,x)] acc = (Sat,) . return . first (:@ ct) . snd <$> x acc
parallel ((ct,x):xs) acc = do
  ctx  <- use context
  (acc', x') <- second (first (:@ ct)) <$> x acc
  ctx1 <- use context
  context .= ctx
  (c', xs') <- parallel xs acc'
  ctx2 <- use context
  let (ctx', ls, rs) = C.merge ctx1 ctx2
  context .= ctx'
  let cls = foldMap (\(n, (t, p, Just p')) -> Drop t (UnusedInOtherBranch n p p')) ls
      crs = foldMap (\(n, (t, p, Just p')) -> Drop t (UnusedInThisBranch  n p p')) rs
  return (c' <> ((cls <> crs) :@ ct) , x':xs')


letBang :: (?loc :: SourcePos) => [VarName] -> (TCType -> CG (Constraint, TCExpr)) -> TCType -> CG (Constraint, TCExpr)
letBang [] x t = x t
letBang bs x t = do
  c <- foldMap id <$> mapM validateVariable bs
  ctx <- use context
  let (ctx', undo) = C.mode ctx bs (\(t,p,p') -> (T (TBang t), p, Just ?loc))
  context .= ctx'
  (c', e) <- x t
  context %= undo
  return (c <> c' <> Escape t UsedInLetBang, e)

validateVariable :: VarName -> CG Constraint
validateVariable v = do
  x <- use context
  return $ if C.contains x v then Sat else Unsat (NotInScope v)



