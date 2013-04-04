{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns  #-}
module CLaSH.Rewrite.Util where

import qualified Control.Monad           as Monad
import Control.Monad.Trans.Class            (lift)
import qualified Control.Monad.Reader    as Reader
import qualified Control.Monad.State     as State
import qualified Control.Monad.Writer    as Writer
import qualified Data.HashMap.Lazy       as HashMap
import           Data.Label.Pure         ((:->))
import qualified Data.Label.PureM        as LabelM
import qualified Data.Map                as Map
import qualified Data.Monoid             as Monoid
import qualified Data.Set                as Set
import qualified Unbound.LocallyNameless as Unbound
import Unbound.LocallyNameless           (Fresh,Collection(..),bind,embed,makeName,name2String,rebind,rec,unbind,unrec,unembed)
import Unbound.Util                      (filterC)

import CLaSH.Core.DataCon (dataConInstArgTys)
import CLaSH.Core.FreeVars (termFreeVars,typeFreeVars)
import CLaSH.Core.Pretty (showDoc)
import CLaSH.Core.Subst (substTm)
import CLaSH.Core.Term (Pat(..),Term(..),TmName,LetBinding)
import CLaSH.Core.TyCon (tyConDataCons)
import CLaSH.Core.Type (Type(..),TyName,TypeView(..),typeKind,tyView,mkTyVarTy)
import CLaSH.Core.Util (Gamma,Delta,collectArgs,termType,mkId,mkTyVar,mkTyLams,mkLams,mkTyApps,mkTmApps,mkApps,mkAbstraction)
import CLaSH.Core.Var  (Var(..),Id,TyVar)
import CLaSH.Netlist.Util (representableType)
import CLaSH.Rewrite.Types
import CLaSH.Util

liftR :: Monad m => m a -> RewriteMonad m a
liftR m = lift . lift . lift . lift $ m

liftRS :: Monad m => m a -> RewriteSession m a
liftRS m = lift . lift . lift $ m

apply :: (Monad m, Functor m) => String -> Rewrite m -> Rewrite m
apply name rewrite ctx expr = R $ do
  lvl <- LabelM.asks dbgLevel
  let before = showDoc expr
  beforeType <- fmap showDoc $ termType expr
  (expr', anyChanged) <- traceIf (lvl >= DebugAll) ("Trying: " ++ name ++ " on:\n" ++ before) $ Writer.listen $ runR $ rewrite ctx expr
  let hasChanged = Monoid.getAny anyChanged
  Monad.when hasChanged $ LabelM.modify transformCounter (+1)
  let after  = showDoc expr'
  afterType <- fmap showDoc $ termType expr'
  traceIf (lvl >= DebugApplied && hasChanged) ("Changes when applying rewrite " ++ name ++ " to:\n" ++ before ++ "\nType:" ++ beforeType ++ "\nResult:\n" ++ after ++ "\nType:" ++ afterType ++ "\n") $
    traceIf (lvl >= DebugAll && not hasChanged) ("No changes when applying rewrite " ++ name ++ " to:\n" ++ before ++ "\n") $
      return expr'

runRewrite :: (Monad m, Functor m) => String -> Rewrite m -> Term -> RewriteSession m Term
runRewrite name rewrite expr = do
  (expr',_) <- Writer.runWriterT . runR $ apply name rewrite [] expr
  return expr'

runRewriteSession ::
  Monad m
  => DebugLevel
  -> RewriteState
  -> RewriteSession m a
  -> m a
runRewriteSession lvl st
  = Unbound.runFreshMT
  . (flip State.evalStateT st)
  . (flip Reader.runReaderT (RE lvl))

setChanged :: Monad m => RewriteMonad m ()
setChanged = Writer.tell (Monoid.Any True)

changed :: Monad m => a -> RewriteMonad m a
changed val = do
  Writer.tell (Monoid.Any True)
  return val

contextEnv ::
  [CoreContext]
  -> (Gamma, Delta)
contextEnv = go HashMap.empty HashMap.empty
  where
    go gamma delta []                   = (gamma,delta)
    go gamma delta (LetBinding ids:ctx) = go gamma' delta ctx
      where
        gamma' = foldl addToGamma gamma ids

    go gamma delta (LetBody ids:ctx)    = go gamma' delta ctx
      where
        gamma' = foldl addToGamma gamma ids

    go gamma delta (LamBody lId:ctx)    = go gamma' delta ctx
      where
        gamma' = addToGamma gamma lId

    go gamma delta (TyLamBody tv:ctx)   = go gamma delta' ctx
      where
        delta' = addToDelta delta tv

    go gamma delta (CaseAlt ids:ctx)    = go gamma' delta ctx
      where
        gamma' = foldl addToGamma gamma ids

    go gamma delta (_:ctx) = go gamma delta ctx

    addToGamma gamma (Id idName ty) = HashMap.insert idName (unembed ty) gamma
    addToGamma gamma _              = error $ $(curLoc) ++ "Adding TyVar to Gamma"

    addToDelta delta (TyVar tvName ki) = HashMap.insert tvName (unembed ki) delta
    addToDelta delta _                 = error $ $(curLoc) ++ "Adding Id to Delta"

mkEnv ::
  (Functor m, Monad m)
  => [CoreContext]
  -> RewriteMonad m (Gamma, Delta)
mkEnv ctx = do
  let (gamma,delta) = contextEnv ctx
  tsMap         <- fmap (HashMap.map fst) $ LabelM.gets bindings
  dfuns         <- fmap (HashMap.map fst) $ LabelM.gets dictFuns
  clsOps        <- fmap (HashMap.map fst) $ LabelM.gets classOps
  let gamma'    = tsMap `HashMap.union` dfuns `HashMap.union` clsOps
                  `HashMap.union` gamma
  return (gamma',delta)

mkTmBinderFor ::
  (Functor m, Fresh m, MonadUnique m)
  => String
  -> Term
  -> m (Id, Term)
mkTmBinderFor name e = do
  (Left r) <- mkBinderFor name (Left e)
  return r

mkBinderFor ::
  (Functor m, Monad m, MonadUnique m, Fresh m)
  => String
  -> (Either Term Type)
  -> m (Either (Id,Term) (TyVar,Type))
mkBinderFor name (Left term) =
  Left <$> (mkInternalVar name =<< termType term)

mkBinderFor name (Right ty) = do
  name'     <- fmap (makeName name . toInteger) getUniqueM
  let kind  = typeKind ty
  return $ Right (TyVar name' (embed kind), VarTy kind name')

mkInternalVar ::
  (Functor m, Monad m, MonadUnique m)
  => String
  -> Type
  -> m (Id,Term)
mkInternalVar name ty = do
  name' <- fmap (makeName name . toInteger) getUniqueM
  return (Id name' (embed ty),Var ty name')

inlineBinders ::
  Monad m
  => (LetBinding -> RewriteMonad m Bool)
  -> Rewrite m
inlineBinders condition _ expr@(Letrec b) = R $ do
  (xes,res)        <- unbind b
  (replace,others) <- partitionM condition (unrec xes)
  case replace of
    [] -> return expr
    _  -> do
      let (others',res') = substituteBinders replace others res
      let newExpr = case others of
                          [] -> res'
                          _  -> Letrec (bind (rec others') res')
      changed newExpr

inlineBinders _ _ e = return e

substituteBinders ::
  [LetBinding]
  -> [LetBinding]
  -> Term
  -> ([LetBinding],Term)
substituteBinders [] others res = (others,res)
substituteBinders ((bndr,valE):rest) others res
  = let val   = unembed valE
        res'  = substTm (varName bndr) val res
        rest' = map (second ( embed
                            . substTm (varName bndr) val
                            . unembed)
                    ) rest
        others' = map (second ( embed
                            . substTm (varName bndr) val
                            . unembed)
                    ) others
    in substituteBinders rest' others' res'

localFreeVars ::
  (Functor m, Monad m, Collection c)
  => Term
  -> RewriteMonad m (c TyName,c TmName)
localFreeVars term = do
  globalBndrs <- LabelM.gets bindings
  dfuns       <- LabelM.gets dictFuns
  clsOps      <- LabelM.gets classOps
  let (tyFVs,tmFVs) = termFreeVars term
  return ( tyFVs
         , filterC
         $ cmap (\v -> if ( v `HashMap.member` globalBndrs ||
                            v `HashMap.member` dfuns       ||
                            v `HashMap.member` clsOps
                          )
                       then Nothing
                       else Just v
                ) tmFVs
         )

liftBinders ::
  (Functor m, Monad m)
  => (LetBinding -> RewriteMonad m Bool)
  -> Rewrite m
liftBinders condition ctx expr@(Letrec b) = R $ do
  (xes,res)        <- unbind b
  (replace,others) <- partitionM condition (unrec xes)
  case replace of
    [] -> return expr
    _  -> do
      (gamma,delta) <- mkEnv ctx
      replace' <- mapM (liftBinding gamma delta) replace
      let (others',res') = substituteBinders replace' others res
      let newExpr = case others of
                          [] -> res'
                          _  -> Letrec (bind (rec others') res')
      changed newExpr

liftBinders _ _ e = return e

liftBinding ::
  (Functor m, Monad m)
  => Gamma
  -> Delta
  -> LetBinding
  -> RewriteMonad m LetBinding
liftBinding gamma delta (Id idName tyE,eE) = do
  let ty = unembed tyE
  let e  = unembed eE
  -- Get all local FVs, excluding the 'idName' from the let-binding
  (localFTVs,localFVs) <- fmap (Set.toList >< Set.toList) $ localFreeVars e
  let localFTVkinds = map (delta HashMap.!) localFTVs
  let localFVs'     = filter (/= idName) localFVs
  let localFVtys'   = map (gamma HashMap.!) localFVs'
  -- Abstract expression over its local FVs
  let boundFTVs = zipWith mkTyVar localFTVkinds localFTVs
  let boundFVs  = zipWith mkId localFVtys' localFVs'
  -- Make a new global ID
  newBodyTy <- termType $ mkTyLams (mkLams e boundFVs) boundFTVs
  newBodyId <- fmap (makeName (name2String idName) . toInteger) getUniqueM
  -- Make a new expression, consisting of the te lifted function applied to
  -- its free variables
  let newExpr = mkTmApps
                  (mkTyApps (Var newBodyTy newBodyId)
                            (zipWith mkTyVarTy localFTVkinds localFTVs))
                  (zipWith Var localFVtys' localFVs')
  -- Substitute the recursive calls by the new expression
  let e' = substTm idName newExpr e
  -- Create a new body that abstracts over the free variables
  let newBody = mkTyLams (mkLams e' boundFVs) boundFTVs
  -- Add the created function to the list of global bindings
  LabelM.modify bindings (HashMap.insert newBodyId (newBodyTy,newBody))
  -- Return the new binder
  return (Id idName (embed ty), embed newExpr)

liftBinding _ _ _ = error $ $(curLoc) ++ "liftBinding: invalid core, expr bound to tyvar"

mkFunction ::
  (Functor m, Monad m)
  => TmName
  -> Term
  -> RewriteMonad m (TmName,Type)
mkFunction bndr body = do
  bodyTy <- termType body
  bodyId <- cloneVar bndr
  addGlobalBind bodyId bodyTy body
  return (bodyId,bodyTy)

addGlobalBind ::
  (Functor m, Monad m)
  => TmName
  -> Type
  -> Term
  -> RewriteMonad m ()
addGlobalBind vId ty body = LabelM.modify bindings (HashMap.insert vId (ty,body))

cloneVar ::
  (Functor m, Monad m)
  => TmName
  -> RewriteMonad m TmName
cloneVar name = fmap (makeName (name2String name) . toInteger) getUniqueM

isLocalVar ::
  (Functor m, Monad m)
  => Term
  -> RewriteMonad m Bool
isLocalVar (Var _ name)
  = fmap (not . HashMap.member name)
  $ LabelM.gets bindings
isLocalVar _ = return False

isUntranslatable ::
  (Functor m, Monad m)
  => Term
  -> RewriteMonad m Bool
isUntranslatable tm = not . representableType <$> termType tm

isLambdaBodyCtx ::
  CoreContext
  -> Bool
isLambdaBodyCtx (LamBody _) = True
isLambdaBodyCtx _           = False

mkWildValBinder ::
  (Functor m, Monad m)
  => Type
  -> RewriteMonad m (Id,Term)
mkWildValBinder ty = mkInternalVar "wild" ty

mkSelectorCase ::
  (Functor m, Monad m)
  => [CoreContext]
  -> Term
  -> Int -- n'th DataCon
  -> Int -- n'th field
  -> RewriteMonad m Term
mkSelectorCase ctx scrut dcI fieldI = do
  scrutTy <- termType scrut
  let delta = snd $ contextEnv ctx
  let cantCreate x = error $ x ++ "Can't create selector for: " ++ showDoc scrutTy
  case scrutTy of
    (tyView -> TyConApp tc args) -> do
      case (tyConDataCons tc) of
        [] -> cantCreate $(curLoc)
        dcs | dcI >= length dcs -> cantCreate $(curLoc)
            | otherwise -> do
          let dc = dcs!!dcI
          let fieldTys = dataConInstArgTys dc args
          if fieldI >= length fieldTys
            then cantCreate $(curLoc)
            else do
              wildBndrs <- mapM mkWildValBinder fieldTys
              selBndr <- mkInternalVar "sel" (fieldTys!!fieldI)
              let bndrs  = take fieldI wildBndrs ++ [selBndr] ++ drop (fieldI+1) wildBndrs
              let pat    = DataPat (embed dc) (rebind [] (map fst bndrs))
              let retVal = Case scrut (fieldTys!!fieldI) [ bind pat (snd selBndr) ]
              return retVal
    _ -> cantCreate $(curLoc)

specialise ::
  (Functor m, State.MonadState s m)
  => (s :-> Map.Map (TmName, Int, Either Term Type) (TmName,Type))
  -> Rewrite m
specialise specMapLbl ctx e@(TyApp e1 ty) = specialise' specMapLbl ctx e (collectArgs e1) (Right ty)
specialise specMapLbl ctx e@(App   e1 e2) = specialise' specMapLbl ctx e (collectArgs e1) (Left  e2)
specialise _          _   e               = return e

specialise' ::
  (Functor m, State.MonadState s m)
  => (s :-> Map.Map (TmName, Int, Either Term Type) (TmName,Type))
  -> [CoreContext]
  -> Term
  -> (Term, [Either Term Type])
  -> Either Term Type
  -> R m Term
specialise' specMapLbl ctx e (Var _ f, args) specArg = R $ do
  -- Create binders and variable references for free variables in 'specArg'
  (specFTVs,specFVs) <- fmap (Set.toList >< Set.toList) $
                        either localFreeVars (pure . (,emptyC) . typeFreeVars) specArg
  (gamma,delta) <- mkEnv ctx
  let (specTyBndrs,specTyVars) = unzip
                 $  map (\tv -> let ki = delta HashMap.! tv
                               in  (Right $ TyVar tv (embed ki), Right $ VarTy ki tv)) specFTVs
  let (specTmBndrs,specTmVars) = unzip
                 $ map (\tm -> let ty = gamma HashMap.! tm
                               in  (Left $ Id tm (embed ty), Left $ Var ty tm)) specFVs
  let argLen = length args
  -- Determine if 'f' has already been specialized on 'specArg'
  specM <- liftR $ fmap (Map.lookup (f,argLen,specArg))
                 $ LabelM.gets specMapLbl
  case specM of
    -- Use previously specialized function
    Just (fname,fty) -> changed $ mkApps (Var fty fname) (args ++ specTyVars ++ specTmVars)
    -- Create new specialized function
    Nothing -> do
      bodyMaybe <- fmap (HashMap.lookup f) $ LabelM.gets bindings
      case bodyMaybe of
        Just (_,bodyTm) -> do
          -- Make new binders for existing arguments
          (boundArgs,argVars) <- fmap unzip $ fmap (map (either (Left >< Left) (Right >< Right))) $
                                 mapM (mkBinderFor "pTS") args
          -- Create specialized functions
          let newBody = mkAbstraction (mkApps bodyTm (argVars ++ [specArg])) (boundArgs ++ specTyBndrs ++ specTmBndrs)
          newf <- mkFunction f newBody
          -- Remember specialization
          liftR $ LabelM.modify specMapLbl
                    (Map.insert (f,argLen,specArg) newf)
          -- use specialized function
          let newExpr = mkApps ((uncurry . flip) Var newf) (args ++ specTyVars ++ specTmVars)
          changed newExpr
        Nothing -> return e

specialise' _ _ e _ _ = return e