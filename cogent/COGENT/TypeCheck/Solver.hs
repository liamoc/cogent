--
-- Copyright 2016, NICTA
--
-- This software may be distributed and modified according to the terms of
-- the GNU General Public License version 2. Note that NO WARRANTY is provided.
-- See "LICENSE_GPLv2.txt" for details.
--
-- @TAG(NICTA_GPL)
--

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}
module COGENT.TypeCheck.Solver (runSolver, solve) where

import COGENT.TypeCheck.Base
import qualified COGENT.TypeCheck.Subst as Subst
import COGENT.TypeCheck.Subst(Subst)
import COGENT.Common.Types
import COGENT.Common.Syntax
import COGENT.Surface
import Control.Monad.State
import Data.List(elemIndex)
import Data.Function(on)
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Set as S
--import qualified Data.List as L
import Control.Lens hiding ((:<))
import qualified Data.Foldable as F
import Data.Monoid
--import Debug.Trace
import COGENT.PrettyPrint(prettyCtx)
import Text.PrettyPrint.ANSI.Leijen (pretty)
import qualified Text.PrettyPrint.ANSI.Leijen as P
import Control.Applicative

data SolverState = SS { _flexes :: Int, _tc :: TCState, _substs :: Subst, _axioms :: [(VarName, Kind)] }

makeLenses ''SolverState

type Solver = State SolverState

data Goal = Goal { _goalContext :: [ErrorContext], _goal :: Constraint }

instance Show Goal where
  show (Goal c g) = const (show big) big
    where big = (small P.<$> (P.vcat $ map (flip prettyCtx True) c))
          small = pretty g


makeLenses ''Goal

-- Flatten a constraint tree into a set of flat goals
crunch :: Constraint -> TC [Goal]
crunch (x :@ e) = map (goalContext %~ (e:)) <$> crunch x
crunch (x :& y) = (++) <$> crunch x <*> crunch y
crunch Sat   = return []
crunch x     = return [Goal [] x]

-- Rewrites out type synonyms, TUnbox, TBang, TTake, and TPut
-- so that the "head" of the type is guaranteed to be a concrete type
-- Operators like TUnbox, TBang etc. are left in place if there is
-- a unification variable.

whnf :: TCType -> TC TCType
whnf (T (TUnbox t)) = do
   t' <- whnf t
   return $ case t' of
     _ | notWhnf t'    -> T (TUnbox t')
     (T (TCon x ps _)) -> T (TCon x ps Unboxed)
     (T (TRecord l _)) -> T (TRecord l Unboxed)
     (T o)             -> T (fmap (T . TUnbox) o)
     _                 -> error "impossible"

whnf (T (TBang t)) = do
   t' <- whnf t
   return $ case t' of
     _ | notWhnf t'    -> T (TBang t')
     (T (TCon x ps s)) -> T (TCon x (map (T . TBang) ps) (bangSigil s))
     (T (TRecord l s)) -> T (TRecord (map (fmap (_1 %~ T . TBang)) l) (bangSigil s))
     (T (TVar b _))    -> T (TVar b True)
     (T o)             -> T (fmap (T . TBang) o)
     _                 -> error "impossible"

whnf (T (TTake fs t)) = do
   t' <- whnf t
   return $ case t' of
     (T (TRecord l s)) -> T (TRecord (takeFields fs l) s)
     _ | Just fs' <- fs, null fs'  -> t'
     _                 -> T (TTake fs t')
 where
   takeFields :: Maybe [FieldName] -> [(FieldName, (TCType, Bool))] -> [(FieldName, (TCType, Bool))]
   takeFields Nothing   = map (fmap (fmap (const True)))
   takeFields (Just fs) = map (\(f, (t, b)) -> (f, (t, f `elem` fs || b)))

whnf (T (TPut fs t)) = do
   t' <- whnf t
   return $ case t' of
     (T (TRecord l s)) -> T (TRecord (putFields fs l) s)
     _ | Just fs' <- fs, null fs'  -> t'
     _                 -> T (TPut fs t')
 where
   putFields :: Maybe [FieldName] -> [(FieldName, (TCType, Bool))] -> [(FieldName, (TCType, Bool))]
   putFields Nothing   = map (fmap (fmap (const False)))
   putFields (Just fs) = map (\(f, (t, b)) -> (f, (t,  (f `notElem` fs) && b)))

whnf (T (TCon n as b)) = do
  kts <- use knownTypes
  case lookup n kts of
    Just (as', Just b) -> whnf (substType (zip as' as) b)
    _ -> return (T (TCon n as b))

whnf (RemoveCase p t) = do
  t' <- whnf t
  return $ fromMaybe (RemoveCase p t') (removeCase p t')
whnf t = return t


-- Used internally in whnf, to check if a type has been normalised. If not,
-- it means that there is a flex or type variable preventing evaluation.
notWhnf :: TCType -> Bool
notWhnf (T TTake  {})    = True
notWhnf (T TPut   {})    = True
notWhnf (T TUnbox {})    = True
notWhnf (T TBang  {})    = True
notWhnf (U u)            = True
notWhnf (RemoveCase t p) = True
notWhnf _                = False

isIrrefutable :: Pattern n -> Bool
isIrrefutable (PIrrefutable p) = True
isIrrefutable _ = False

patternTag :: Pattern n -> Maybe TagName
patternTag (PCon t _) = Just t
patternTag _ = Nothing

isVarCon :: Pattern a -> Bool
isVarCon (PCon {}) = True
isVarCon _ = False
-- Explodes a rigid/rigid constraint into subgoals necessary
-- for that to be true. E.g, (a,b) :< (c,d) becomes a :< c :& b :< d.
-- Assumes that the input is simped (i.e conjunction and context free, with types in whnf)
rule' :: Constraint -> Maybe Constraint
rule' c = fmap (:@ SolvingConstraint c) $ rule c
rule :: Constraint -> Maybe Constraint

rule (Exhaustive t ps) | any isIrrefutable ps = Just Sat
rule (Exhaustive (T (TVariant n)) ps)
  | s1 <- S.fromList (mapMaybe patternTag ps)
  , s2 <- M.keysSet n
  = if s1 == s2
    then Just Sat
    else Just $ Unsat (PatternsNotExhaustive (T (TVariant n)) (S.toList (s2 S.\\ s1)))

rule (Exhaustive (T (TCon "Bool" [] Unboxed)) [PBoolLit t, PBoolLit f])
   = if not (t && f) && (t || f) then Just Sat
     else Just $ Unsat $ PatternsNotExhaustive (T (TCon "Bool" [] Unboxed)) []

rule (Exhaustive t ps)
  | not (notWhnf t) = Just $ Unsat $ PatternsNotExhaustive t []

rule (x :@ c) = (:@ c) <$> rule x
rule (x :& y) = (:&) <$> x' <*> y'
             <|> (x :&) <$> y'
             <|> (:& y) <$> x'
  where y' = rule y
        x' = rule x

rule Unsat {} = Nothing
rule Sat   {} = Nothing

rule (Share  (T TVar {}) _) = Nothing
rule (Drop   (T TVar {}) _) = Nothing
rule (Escape (T TVar {}) _) = Nothing

rule (Share  (T (TTuple xs)) m) = Just $ mconcat $ map (flip Share m) xs
rule (Escape (T (TTuple xs)) m) = Just $ mconcat $ map (flip Escape m) xs
rule (Drop   (T (TTuple xs)) m) = Just $ mconcat $ map (flip Drop m) xs

rule (Share  (T TUnit) m) = Just Sat
rule (Escape (T TUnit) m) = Just Sat
rule (Drop   (T TUnit) m) = Just Sat

rule (Share  (T TFun {}) m) = Just Sat
rule (Escape (T TFun {}) m) = Just Sat
rule (Drop   (T TFun {}) m) = Just Sat

rule (Share  (T (TVariant n)) m) = Just $ foldMap (mconcat . map (flip Share m)) n
rule (Drop   (T (TVariant n)) m) = Just $ foldMap (mconcat . map (flip Drop  m)) n
rule (Escape (T (TVariant n)) m) = Just $ foldMap (mconcat . map (flip Escape m)) n

rule (Share  t@(T (TRecord fs s)) m)
  | s /= Writable = Just $ foldMap (\(x, t) -> if not t then Share x m else Sat) $ map snd fs
  | otherwise     = Just $ Unsat $ TypeNotShareable t m
rule (Drop   t@(T (TRecord fs s)) m)
  | s /= Writable = Just $ foldMap (\(x, t) -> if not t then Drop x m else Sat) $ map snd fs
  | otherwise     = Just $ Unsat $ TypeNotDiscardable t m
rule (Escape t@(T (TRecord fs s)) m)
  | s /= ReadOnly = Just $ foldMap (\(x, t) -> if not t then Escape x m else Sat) $ map snd fs
  | otherwise     = Just $ Unsat $ TypeNotEscapable t m

rule (Share  t@(T (TCon n ts s)) m)
  | s /= Writable = Just Sat
  | otherwise     = Just $ Unsat $ TypeNotShareable t m
rule (Drop   t@(T (TCon n ts s)) m)
  | s /= Writable = Just Sat
  | otherwise     = Just $ Unsat $ TypeNotDiscardable t m
rule (Escape t@(T (TCon n ts s)) m)
  | s /= ReadOnly = Just Sat
  | otherwise     = Just $ Unsat $ TypeNotEscapable t m

rule (T (TTuple xs) :< T (TTuple ys))
  | length xs /= length ys = Just $ Unsat (TypeMismatch (T (TTuple xs)) (T (TTuple ys)))
  | otherwise              = Just $ mconcat (zipWith (:<) xs ys)
rule (T (TFun a b)  :< T (TFun c d)) = Just $ (c :< a) :& (b :< d)
rule (T TUnit       :< T TUnit)      = Just Sat
rule (T (TVar v b)  :< T (TVar u c))
  | v == u, b == c = Just Sat
  | otherwise      = Just $ Unsat (TypeMismatch (T (TVar v b)) (T (TVar u c)))
rule (T (TCon n ts s) :< T (TCon m us r))
  | n == m, length ts == length us, s == r = Just $ mconcat (zipWith (:<) ts us ++ zipWith (:<) us ts)
  | otherwise                              = Just $ Unsat (TypeMismatch (T (TCon n ts s)) (T (TCon m us r)))
rule (T (TRecord fs s) :< T (TRecord gs r))
  | or (zipWith ((/=) `on` fst) fs gs) = Just $ Unsat (TypeMismatch (T (TRecord fs s)) (T (TRecord gs r)))
  | length fs /= length gs             = Just $ Unsat (TypeMismatch (T (TRecord fs s)) (T (TRecord gs r)))
  | s /= r                             = Just $ Unsat (TypeMismatch (T (TRecord fs s)) (T (TRecord gs r)))
  | otherwise                          = let
      each (f, (t, False)) (_, (u, True )) = (t :< u) :& Drop t ImplicitlyTaken
      each (f, (t, False)) (_, (u, False)) = t :< u
      each (f, (t, True )) (_, (u, True )) = t :< u
      each (f, (t, True )) (_, (u, False)) = Unsat (RequiredTakenField f t)
    in Just $ mconcat (zipWith each fs gs)
rule (T (TVariant m) :< T (TVariant n))
  | M.keys m /= M.keys n = Just $ Unsat (TypeMismatch (T (TVariant m)) (T (TVariant n)))
  | otherwise = let
      each ts us = mconcat (zipWith (:<) ts us)
    in Just $ mconcat (zipWith (each `on` snd) (M.toList m) (M.toList n))
-- This rule is a bit dodgy
-- rule (T (TTake (Just a) b) :< T (TTake (Just a') c))
--   | x <- L.intersect a a'
--   , not (null x)
--   = let
--       ax  = a L.\\ x
--       a'x = a' L.\\ x
--      in Just $  ((if null ax then id else T . TTake (Just ax)) b)
--              :< ((if null a'x then id else T . TTake (Just a'x)) c)
rule (a :< b)
  | notWhnf a || notWhnf b = Nothing -- traceShow ("FOO", a :< b) Nothing
  | otherwise              = Just $ Unsat (TypeMismatch a b)

rule (T (TCon n [] Unboxed) :<~ T (TCon m [] Unboxed))
  | Just n' <- elemIndex n primTypeCons
  , Just m' <- elemIndex m primTypeCons
  , n' <= m'
  , m /= "String"
  = Just Sat
rule (T (TVariant n) :<~ T (TVariant m))
  | ks <- M.keysSet n
  , ks `S.isSubsetOf` M.keysSet m
  = let each ts us = mconcat (zipWith (:<) ts us)
    in Just $ mconcat (map (\k -> each (n M.! k) (m M.! k)) $ S.toList ks)
rule (T (TRecord fs _) :<~ T (TRecord gs s))
  | ks <- S.fromList (map fst fs)
  , m <- M.fromList gs
  , ks `S.isSubsetOf` M.keysSet m
  , n <- M.fromList fs
  =  let
       each f (t, True)  (u, False) = (t :< u) :& Drop t ImplicitlyTaken
       each f (t, False) (u, False) = t :< u
       each f (t, True ) (u, True ) = t :< u
       each f (t, False) (u, True) = Unsat (RequiredTakenField f t)
     in Just $ mconcat (map (\k -> each k (n M.! k) (m M.! k)) $ S.toList ks)
rule (a :<~ b) = rule (a :< b)
rule c = Nothing

-- Applys rules and simp as much as possible
auto :: Constraint -> TC Constraint
auto c = do
  c' <- simp c
  case rule' c' of
    Nothing  -> return c'
    Just c'' -> auto c''

apply :: (Constraint -> TC Constraint) -> [Goal] -> TC [Goal]
apply tactic = fmap concat . mapM each
  where each (Goal ctx c) = do
          c' <- tactic c
          map (goalContext %~ (ctx ++)) <$> crunch c'


-- applies whnf to every type in a constraint.
simp :: Constraint -> TC Constraint
simp (a :< b)     = (:<)   <$> whnf a <*> whnf b
simp (a :<~ b)    = (:<~)  <$> whnf a <*> whnf b
simp (a :& b)     = (:&)   <$> simp a <*> simp b
simp (Share t m)  = Share  <$> whnf t <*> pure m
simp (Drop  t m)  = Drop   <$> whnf t <*> pure m
simp (Escape t m) = Escape <$> whnf t <*> pure m
simp (a :@ c)     = (:@)   <$> simp a <*> pure c
simp (Unsat e)    = pure (Unsat e)
simp Sat          = pure Sat
simp (Exhaustive t ps)
  = Exhaustive <$> whnf t
               <*> traverse (traverse (traverse whnf)) ps -- poetry!

fresh :: Solver TCType
fresh = U <$> (flexes <<%= succ)

-- Constructs a partially specified type that could plausibly be :< the two inputs.
-- We re-check some basic equalities here for better error messages
glb :: TCType -> TCType -> Solver (Maybe TCType)
glb (T (TVariant is)) (T (TVariant js))
  | M.keysSet is /= M.keysSet js
  = return Nothing
  | or (zipWith ((/=) `on` length) (F.toList is) (F.toList js))
  = return Nothing
  | otherwise
  = Just . T . TVariant <$> traverse (\l -> replicateM (length l) fresh) is
glb (T (TTuple is)) (T (TTuple js))
  | length is /= length js = return Nothing
  | otherwise = Just . T . TTuple <$> traverse (const fresh) is
glb (T (TFun a b)) (T (TFun c d))
  = Just . T <$> (TFun <$> fresh <*> fresh)
glb (T (TCon c as s)) (T (TCon d bs r))
  | c /= d || s /= r       = return Nothing
  | length as /= length bs = return Nothing
  | otherwise = Just . T <$> (TCon d <$> traverse (const fresh) as <*> pure r)
glb (T (TVar a x)) (T (TVar b y))
  | x /= y || a /= b = return Nothing
  | otherwise        = return $ Just . T $ TVar a x
glb (T TUnit) (T TUnit) = return $ Just (T TUnit)
glb (T (TRecord fs s)) (T (TRecord gs r))
  | s /= r = return Nothing
  | map fst fs /= map fst gs = return Nothing
  | otherwise = let
      each (f,(_,b)) (_, (_,b')) = (f,) . (,b && b') <$> fresh
    in Just . T <$> (TRecord <$> zipWithM each fs gs <*> pure s)
glb _ _ = return Nothing



-- Constructs a partially specified type that the two inputs are plausibly both :<.
-- Once again we recheck equalities for error message improvements.
lub :: TCType -> TCType -> Solver (Maybe TCType)
lub (T (TVariant is)) (T (TVariant js))
  | M.keysSet is /= M.keysSet js
  = return Nothing
  | or (zipWith ((/=) `on` length) (F.toList is) (F.toList js))
  = return Nothing
  | otherwise
  = Just . T . TVariant <$> traverse (\l -> replicateM (length l) fresh) is
lub (T (TTuple is)) (T (TTuple js))
  | length is /= length js = return Nothing
  | otherwise = Just . T . TTuple <$> traverse (const fresh) is
lub (T (TFun a b)) (T (TFun c d))
  = Just . T <$> (TFun <$> fresh <*> fresh)
lub (T (TCon c as s)) (T (TCon d bs r))
  | c /= d || s /= r       = return Nothing
  | length as /= length bs = return Nothing
  | otherwise = Just . T <$> (TCon d <$> traverse (const fresh) as <*> pure r)
lub (T (TVar a x)) (T (TVar b y))
  | x /= y || a /= b = return Nothing
  | otherwise        = return $ Just . T $ TVar a x
lub (T TUnit) (T TUnit) = return $ Just (T TUnit)
lub (T (TRecord fs s)) (T (TRecord gs r))
  | s /= r = return Nothing
  | map fst fs /= map fst gs = return Nothing
  | otherwise = let
      each (f,(_,b)) (_, (_,b')) = (f,) . (,b || b') <$> fresh
    in Just . T <$> (TRecord <$> zipWithM each fs gs <*> pure s)
lub _ _ = return Nothing

-- Constructs a partially specified type that the two inputs are plausibly both :<~.
-- A GLB equivalent isn't needed here, because these constraints only ever appear
-- with a unification variable on the right, and they expand into regular subtyping constraints with rule.
-- This is used to essentially "guess" the type when we don't have firm enough information
-- My intention is to try solving _without_ this entirely and seeing how far I get.
lub' :: TCType -> TCType -> Solver (Maybe TCType)
-- lub' (T (TVariant ts)) (T (TVariant us))
--   = Just . T . TVariant <$> mapM (mapM (const fresh)) (M.union ts us)
-- lub' (T (TRecord fs s)) (T (TRecord gs r))
--   | s /= r = return Nothing
--   | fs' <- M.fromList fs, gs' <- M.fromList gs
--   , hs <- M.unionWith (\(t,b) (_,b') -> (t, b || b')) fs' gs'
--   = do hs' <- M.toList <$> traverse (\(_,b) -> (,b) <$> fresh) hs
--        return $ Just $ T $ TRecord hs' s
lub' (T (TCon n [] Unboxed)) (T (TCon m [] Unboxed))
     | Just n' <- elemIndex n primTypeCons
     , Just m' <- elemIndex m primTypeCons
     = return $ Just (T (TCon (primTypeCons !! max n' m') [] Unboxed))
lub' a b = return Nothing


-- A simple classification scheme for soluble flex/rigid constraints
data GoalClasses
  = Classes
    { ups :: M.Map Int [Goal]
    , downs :: M.Map Int [Goal]
    , fragments :: M.Map Int [Goal]
    , unsats :: [Goal]
    , rest :: [Goal]
    }

instance Show GoalClasses where
  show (Classes u d f un r) = "ups:\n" ++
                              unlines (map (("  " ++) . show) (F.toList u)) ++
                              "\ndowns:\n" ++
                              unlines (map (("  " ++) . show) (F.toList d)) ++
                              "\nfragments:\n" ++
                              unlines (map (("  " ++) . show) (F.toList f)) ++
                              "\nunsats:\n" ++
                              unlines (map (("  " ++) . show) (F.toList un)) ++
                              "\nrest:\n" ++
                              unlines (map (("  " ++) . show) (F.toList r)) 
instance Monoid GoalClasses where
  Classes u d f e r `mappend` Classes u' d' f' e' r'
    = Classes (M.unionWith (++) u u')
              (M.unionWith (++) d d')
              (M.unionWith (++) f f')
              (e ++ e')
              (r ++ r')

  mempty = Classes M.empty M.empty M.empty [] []

exhaustives :: Goal -> Solver Goal
exhaustives (Goal ctx (Exhaustive (U x) ps)) | all isVarCon ps = do
        ts <- fromPatterns ps
        return (Goal [] $ U x :< T (TVariant ts))
  where
    fromPattern :: Pattern TCTypedName -> Solver (M.Map TagName [TCType])
    fromPattern (PCon t ps) = M.singleton t <$> (mapM (const fresh) ps)
    fromPattern _ = error "impossible"
    fromPatterns ps = mconcat <$> mapM fromPattern ps
exhaustives x = return x

-- Break goals into their form
-- Expects all goals to be broken down as far as possible first
-- Consider using auto first, or using explode instead of this function.
classify :: Goal -> GoalClasses
classify g = case g of
  (Goal _ (T _ :< U x)) -> Classes (M.singleton x [g]) M.empty M.empty [] []
  (Goal _ (U x :< T _)) -> Classes M.empty (M.singleton x [g]) M.empty [] []
  (Goal _ (_  :<~ U x)) -> Classes M.empty M.empty (M.singleton x [g]) [] []
  (Goal _ (Unsat _))    -> Classes M.empty M.empty M.empty [g] []
  (Goal _ Sat)          -> mempty
  _                     -> Classes M.empty M.empty M.empty [] [g]




-- Push type information down from the RHS of :< to the LHS
-- Expects a series of goals of the form U x :< tau
impose :: [Goal] -> Solver [Goal]
impose (Goal x1 (v :< tau) : Goal x2 (_ :< tau') : xs) = do
  mt <- glb tau tau'
  case mt of
    Nothing    -> return [Goal x1 (Unsat (TypeMismatch tau tau'))]
    Just tau'' -> ([Goal x1 (tau'' :< tau), Goal x2 (tau'' :< tau')] ++)
                  <$> impose (Goal x2 (v :< tau'') : xs)
impose xs = return xs

-- Push type information up from the LHS of :< to the RHS
-- Expects a series of goals of the form tau :< U x
suggest :: [Goal] -> Solver [Goal]
suggest (Goal x1 (tau :< v) : Goal x2 (tau' :< _) : xs) = do
  mt <- lub tau tau'
  case mt of
    Nothing    -> return [Goal x1 (Unsat (TypeMismatch tau tau'))]
    Just tau'' -> ([Goal x1 (tau :< tau''), Goal x2 (tau' :< tau'')] ++)
                  <$> suggest (Goal x2 (tau'' :< v) : xs)
suggest xs = return xs


guess :: [Goal] -> Solver [Goal]
guess (Goal x1 a@(tau :<~ v) : Goal x2 b@(tau' :<~ _) : xs) = do
  mt <- lub' tau tau'
  case mt of
    Nothing    -> return [Goal x1 (Unsat (UnsolvedConstraint (a :& b)))]
    Just tau'' -> ([Goal x1 (tau :< tau''), Goal x2 (tau' :< tau'')] ++)
                  <$> suggest (Goal x2 (tau'' :< v) : xs)

guess xs = return xs
-- Produce substitutions when it is safe to do so (the variable can't get any more general)
noBrainers :: [Goal] -> Subst
noBrainers [Goal _ (U x :<  T t)] = Subst.singleton x (T t)
noBrainers [Goal _ (T t :<  U x)] = Subst.singleton x (T t)
noBrainers [Goal _ (T t@(TCon v [] Unboxed) :<~ U x)] | v `elem` primTypeCons = Subst.singleton x (T t)
noBrainers _ = mempty


applySubst :: Subst -> Solver ()
applySubst s = substs <>= s

-- Applies the current substitution to goals.
instantiate :: GoalClasses -> Solver [Goal]
instantiate (Classes ups downs frags errs rest) = do
  s <- use substs
  let al = concat (F.toList ups ++ F.toList downs ++ F.toList frags) ++ errs ++ rest
  return (al & map (goal %~ Subst.applyC s) & map (goalContext %~ map (Subst.applyCtx s)))


-- Eliminates all known facts about type variables from the goal set.
assumption :: [Goal] -> Solver [Goal]
assumption gs = do
  axs <- use axioms
  let isKnown :: Constraint -> Bool
      isKnown (Share  (T (TVar v b)) _)
        | Just k <- lookup v axs = canShare   (if b then bangKind k else k)
      isKnown (Drop   (T (TVar v b)) _)
        | Just k <- lookup v axs = canDiscard (if b then bangKind k else k)
      isKnown (Escape (T (TVar v b)) _)
        | Just k <- lookup v axs = canEscape  (if b then bangKind k else k)
      isKnown _ = False
  return (filter (not  . isKnown . view goal) gs)

-- Take an assorted list of goals, and break them down into neatly classified, simple flex/rigid goals.
-- Removes any known facts about type variables.
explode :: [Goal] -> Solver GoalClasses
explode = assumption >=> (zoom tc . apply auto) >=> mapM exhaustives >=> (return . foldMap classify)


-- In a loop, we:
--   1. Smash all goals into smaller, simple flex/rigid goals. Exit if any of them are Unsat, remove any Sat.
--   2.1. Apply any no-brainer substitutions from the downward goals (? :< R)
--        If we did any substituting go to 1
--   2.2. If there are any downward goals,
--          Push type information down from the RHS to the LHS of :< constraints and go to 1
--   3.1. Apply any no-brainer substitutions from the upward goals (R :< ?)
--        If we did any substituting, go to 1
--   3.2. If there are any upward goals,
--          Pull type information up from the LHS to the RHS of :< constraints and go to 1
--   4. If there are any remaining constraints, report unsolved error, otherwise return empty list.
solve :: Constraint -> Solver [ContextualisedError]
solve = zoom tc . crunch >=> explode >=> go
  where
    go :: GoalClasses -> Solver [ContextualisedError]
    --go g | traceShow g False = undefined
    go g | not (null (unsats g)) = return $ map toError (unsats g)

    go g | not (M.null (downs g)) = do
      let s = foldMap noBrainers (downs g)
      if Subst.null s then do
          g' <- explode =<< concat . F.toList <$> traverse impose (downs g)
          go (g' <> g { downs = M.empty } )
      else do
          applySubst s
          instantiate g >>= explode >>= go

    go g | not (M.null (ups g)) = do
      let s = foldMap noBrainers (ups g)
      if Subst.null s then do
          g' <- explode =<< concat . F.toList <$> traverse suggest (ups g)
          go (g' <> g { ups = M.empty } )
      else do
          applySubst s
          instantiate g >>= explode >>= go

    go g | not (M.null (fragments g)) = do
      let s = foldMap noBrainers (fragments g)
      if Subst.null s then do
          g' <- explode =<< concat . F.toList <$> traverse guess (fragments g)
          go (g' <> g { ups = M.empty } )
      else do
          applySubst s
          instantiate g >>= explode >>= go
      -- let f (Goal c x) = (c, UnsolvedConstraint x)
      -- in  return $ map f $ concat $ F.toList (fragments g)

    go g | not (null (rest g)) =
      let f (Goal c x) = (c, UnsolvedConstraint x)
      in  return $ map f (rest g)

    go _ = return []

    toError :: Goal -> ContextualisedError
    toError (Goal ctx (Unsat e)) = (ctx, e)
    toError _ = error "Impossible"

runSolver :: Solver a -> Int -> [(VarName, Kind)] -> TC (a, Subst)
runSolver act i ks = do
  x <- get
  let (a, SS _ x' s _) = runState act (SS i x mempty ks)
  put x'
  return (a,s)
