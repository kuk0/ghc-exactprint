{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Language.Haskell.GHC.ExactPrint
-- Based on
-- --------------------------------------------------------------------------
-- Module      :  Language.Haskell.Exts.Annotated.ExactPrint
-- Copyright   :  (c) Niklas Broberg 2009
-- License     :  BSD-style (see the file LICENSE.txt)
--
-- Maintainer  :  Niklas Broberg, d00nibro@chalmers.se
-- Stability   :  stable
-- Portability :  portable
--
-- Exact-printer for Haskell abstract syntax. The input is a (semi-concrete)
-- abstract syntax tree, annotated with exact source information to enable
-- printing the tree exactly as it was parsed.
--
-----------------------------------------------------------------------------
module Language.Haskell.GHC.ExactPrint
        ( annotate
        , exactPrintAnnotated
        , exactPrintAnnotation

        , exactPrint
        , ExactP

        , toksToComments
        ) where

import Language.Haskell.GHC.ExactPrint.Types
import Language.Haskell.GHC.ExactPrint.Utils

import Control.Monad (when, liftM, ap)
import Control.Applicative (Applicative(..))
import Control.Arrow ((***), (&&&))
import Data.Data
import Data.List (intersperse)
import Data.List.Utils
import Data.Maybe

import qualified Bag           as GHC
import qualified BasicTypes    as GHC
import qualified DynFlags      as GHC
import qualified FastString    as GHC
import qualified ForeignCall   as GHC
import qualified GHC           as GHC
import qualified GHC.Paths     as GHC
import qualified Lexer         as GHC
import qualified Name          as GHC
import qualified NameSet       as GHC
import qualified Outputable    as GHC
import qualified RdrName       as GHC
import qualified SrcLoc        as GHC
import qualified StringBuffer  as GHC
import qualified UniqSet       as GHC
import qualified Unique        as GHC
import qualified Var           as GHC

import qualified Data.Map as Map

import qualified GHC.SYB.Utils as SYB

import Debug.Trace

debug :: c -> String -> c
debug = flip trace

-- ---------------------------------------------------------------------

-- Compatibiity types, from HSE

-- | A portion of the source, extended with information on the position of entities within the span.
data SrcSpanInfo = SrcSpanInfo
    { srcInfoSpan    :: GHC.SrcSpan
    , srcInfoPoints  :: [GHC.SrcSpan]    -- Marks the location of specific entities inside the span
    }
  deriving (Eq,Ord,Show,Typeable,Data)


-- | A class to work over all kinds of source location information.
class SrcInfo si where
  toSrcInfo   :: GHC.SrcLoc -> [GHC.SrcSpan] -> GHC.SrcLoc -> si
  fromSrcInfo :: SrcSpanInfo -> si
  getPointLoc :: si -> GHC.SrcLoc
  fileName    :: si -> String
  startLine   :: si -> Int
  startColumn :: si -> Int

  getPointLoc si = GHC.mkSrcLoc (GHC.mkFastString $ fileName si) (startLine si) (startColumn si)


instance SrcInfo GHC.SrcSpan where
  toSrcInfo   = error "toSrcInfo GHC.SrcSpan undefined"
  fromSrcInfo = error "toSrcInfo GHC.SrcSpan undefined"

  getPointLoc = GHC.srcSpanStart

  fileName (GHC.RealSrcSpan s) = GHC.unpackFS $ GHC.srcSpanFile s
  fileName _                   = "bad file name for SrcSpan"

  startLine   = srcSpanStartLine
  startColumn = srcSpanStartColumn



class Annotated a where
  ann :: a -> GHC.SrcSpan

instance Annotated (GHC.Located a) where
  ann (GHC.L l _) = l


-- | Test if a given span starts and ends at the same location.
isNullSpan :: GHC.SrcSpan -> Bool
isNullSpan ss = spanSize ss == (0,0)

spanSize :: GHC.SrcSpan -> (Int, Int)
spanSize ss = (srcSpanEndLine ss - srcSpanStartLine ss,
               max 0 (srcSpanEndColumn ss - srcSpanStartColumn ss))

toksToComments :: [PosToken] -> [Comment]
toksToComments toks = map tokToComment $ filter ghcIsComment toks
  where
    tokToComment t@(GHC.L l _,s) = Comment (ghcIsMultiLine t) ((ss2pos l),(ss2posEnd l)) s


------------------------------------------------------
-- The EP monad and basic combinators

pos :: (SrcInfo loc) => loc -> Pos
pos ss = (startLine ss, startColumn ss)

newtype EP x = EP (Pos -> DeltaPos -> [Comment] -> Anns
            -> (x, Pos,   DeltaPos,   [Comment],   Anns, ShowS))

instance Functor EP where
  fmap = liftM

instance Applicative EP where
  pure = return
  (<*>) = ap

instance Monad EP where
  return x = EP $ \l dp cs an -> (x, l, dp, cs, an, id)

  EP m >>= k = EP $ \l0 dp0 c0 an0 -> let
        (a, l1, dp1, c1, an1, s1) = m l0 dp0 c0 an0
        EP f = k a
        (b, l2, dp2, c2, an2, s2) = f l1 dp1 c1 an1
    in (b, l2, dp2, c2, an2, s1 . s2)

runEP :: EP () -> [Comment] -> Anns -> String
runEP (EP f) cs ans = let (_,_,_,_,_,s) = f (1,1) (DP (0,0)) cs ans in s ""

getPos :: EP Pos
getPos = EP (\l dp cs an -> (l,l,dp,cs,an,id))

setPos :: Pos -> EP ()
setPos l = EP (\_ dp cs an -> ((),l,dp,cs,an,id))


getOffset :: EP DeltaPos
getOffset = EP (\l dp cs an -> (dp,l,dp,cs,an,id))

setOffset :: DeltaPos -> EP ()
setOffset dp = EP (\l _ cs an -> ((),l,dp,cs,an,id))


getAnnotation :: GHC.SrcSpan -> EP (Maybe [Annotation])
getAnnotation ss = EP (\l dp cs an -> (Map.lookup ss an,l,dp,cs,an,id))

putAnnotation :: GHC.SrcSpan -> [Annotation] -> EP ()
putAnnotation ss anns = EP (\l dp cs an ->
  let
    an' = Map.insert ss anns an
  in ((),l,dp, cs,an',id))

printString :: String -> EP ()
printString str = EP (\(l,c) dp cs an -> ((), (l,c+length str), dp, cs, an, showString str))

getComment :: EP (Maybe Comment)
getComment = EP $ \l dp cs an ->
    let x = case cs of
             c:_ -> Just c
             _   -> Nothing
     in (x, l, dp, cs, an, id)

dropComment :: EP ()
dropComment = EP $ \l dp cs an ->
    let cs' = case cs of
               (_:cs) -> cs
               _      -> cs
     in ((), l, dp, cs', an, id)

mergeComments :: [DComment] -> EP ()
mergeComments dcs = EP $ \l dp cs an ->
    let acs = map (undeltaComment l) dcs
        cs' = merge acs cs
    in ((), l, dp, cs', an, id) -- `debug` ("mergeComments:(l,acs)=" ++ show (l,acs,cs))

newLine :: EP ()
newLine = do
    (l,_) <- getPos
    printString "\n"
    setPos (l+1,1)

padUntil :: Pos -> EP ()
padUntil (l,c) = do
    (l1,c1) <- getPos
    case  {- trace (show ((l,c), (l1,c1))) -} () of
     _ {-()-} | l1 >= l && c1 <= c -> printString $ replicate (c - c1) ' '
              | l1 < l             -> newLine >> padUntil (l,c)
              | otherwise          -> return ()

padDelta :: DeltaPos -> EP ()
padDelta (DP (dl,dc)) = do
    (l1,c1) <- getPos
    let (l,c) = (l1+dl,c1+dc)
    case  {- trace (show ((l,c), (l1,c1))) -} () of
     _ {-()-} | l1 >= l && c1 <= c -> printString $ replicate (c - c1) ' '
              | l1 < l             -> newLine >> padUntil (l,c)
              | otherwise          -> return ()


mPrintComments :: Pos -> EP ()
mPrintComments p = do
    mc <- getComment
    case mc of
     Nothing -> return ()
     Just (Comment multi (s,e) str) ->
        when (s < p) $ do
            dropComment
            padUntil s
            printComment multi str
            setPos e
            mPrintComments p

printComment :: Bool -> String -> EP ()
printComment b str
    | b         = printString str
    | otherwise = printString str

-- Single point of delta application
printWhitespace :: Pos -> EP ()
printWhitespace (r,c) = do
  DP (dr,dc)  <- getOffset
  let p = (r + dr, c + dc)
  mPrintComments p >> padUntil p

printStringAt :: Pos -> String -> EP ()
printStringAt p str = printWhitespace p >> printString str

printStringAtDelta :: DeltaPos -> String -> EP ()
printStringAtDelta (DP (dl,dc)) str = do
  (l1,c1) <- getPos
  let (l,c) = (l1 + dl, c1 + dc)
  printWhitespace (l,c) >> printString str

printStringAtMaybe :: Maybe Pos -> String -> EP ()
printStringAtMaybe mc s =
  case mc of
    Nothing -> return ()
    Just cl -> printStringAt cl s

printStringAtMaybeDelta :: Maybe DeltaPos -> String -> EP ()
printStringAtMaybeDelta mc s =
  case mc of
    Nothing -> return ()
    Just cl -> do
      p <- getPos
      printStringAt (undelta p cl) s

printStringAtMaybeDeltaP :: Pos -> Maybe DeltaPos -> String -> EP ()
printStringAtMaybeDeltaP p mc s =
  case mc of
    Nothing -> return ()
    Just cl -> do
      printStringAt (undelta p cl) s

printListCommaMaybe :: Maybe [Annotation] -> EP ()
printListCommaMaybe Nothing = return ()
printListCommaMaybe ma = do
  case getAnn isAnnListItem ma "ListItem" of
    [Ann _ _ (AnnListItem commaPos)] -> do
      printStringAtMaybeDelta commaPos ","
    _ -> return ()


errorEP :: String -> EP a
errorEP = fail

------------------------------------------------------------------------------
-- Printing of source elements

-- | Print an AST exactly as specified by the annotations on the nodes in the tree.
-- exactPrint :: (ExactP ast) => ast -> [Comment] -> String
exactPrint :: (ExactP ast) => GHC.Located ast -> [Comment] -> [PosToken] -> String
exactPrint ast cs toks = runEP (exactPC ast) cs Map.empty


exactPrintAnnotated ::
     GHC.Located (GHC.HsModule GHC.RdrName)
  -> [Comment] -> [PosToken] -> String
exactPrintAnnotated ast cs toks = runEP (exactPC ast) [] ann
  where
    ann = annotateLHsModule ast cs toks

exactPrintAnnotation :: ExactP ast =>
  GHC.Located ast -> [Comment] -> Anns -> String
exactPrintAnnotation ast cs ann = runEP (exactPC ast) cs ann
  -- `debug` ("exactPrintAnnotation:ann=" ++ (concatMap (\(l,a) -> show (ss2span l,a)) $ Map.toList ann ))

annotate :: GHC.Located (GHC.HsModule GHC.RdrName) -> [Comment] -> [PosToken] -> Anns
annotate ast cs toks = annotateLHsModule ast cs toks

-- |First move to the given location, then call exactP
exactPC :: (ExactP ast) => GHC.Located ast -> EP ()
exactPC (GHC.L l ast) =
 let p = pos l
 in do ma <- getAnnotation l
       mPrintComments p
       padUntil p
       case ma of
         Nothing -> return ()
         Just anns -> do
             mergeComments lcs
             putAnnotation l anns'
           where lcs = concatMap (\(Ann cs _ _) -> cs) anns
                 anns' = map (\(Ann _ p a) -> Ann [] p a) anns
       exactP ma ast
       printListCommaMaybe ma

{-
exactPCTrailingComma :: (ExactP ast) => GHC.Located ast -> EP ()
exactPCTrailingComma a@(GHC.L l _) = do
  exactPC a
  ma <- getAnnotation l
  case getAnn isAnnListItem ma "ListItem" of
    [Ann _ _ (AnnListItem commaPos)] -> do
      printStringAtMaybeDelta commaPos ","
    _ -> return ()
-}

printSeq :: [(Pos, EP ())] -> EP ()
printSeq [] = return ()
printSeq ((p,pr):xs) = printWhitespace p >> pr >> printSeq xs

printStrs :: SrcInfo loc => [(loc, String)] -> EP ()
printStrs = printSeq . map (pos *** printString)

printPoints :: SrcSpanInfo -> [String] -> EP ()
printPoints l = printStrs . zip (srcInfoPoints l)

printInterleaved :: (Annotated ast, SrcInfo loc, ExactP ast) => [(loc, String)] -> [ast] -> EP ()
printInterleaved sistrs asts = printSeq $
    interleave (map (pos *** printString ) sistrs)
               (map (pos . ann &&& exactP') asts)
  where
    exactP' ast = do
      ma <- getAnnotation (ann ast)
      exactP ma ast

-- so, f ast = pos $ ann ast
--     g ast = exactP ast

{-

The default definition may be overridden with a more efficient version if desired.

(***) :: a b c -> a b' c' -> a (b, b') (c, c') -- infixr 3
  Split the input between the two argument arrows and combine their output.
  Note that this is in general not a functor.
f *** g = first f >>> second g


(&&&) :: a b c -> a b c' -> a b (c, c') -- infixr 3
  Fanout: send the input to both argument arrows and combine their output.
f &&& g = arr (\b -> (b,b)) >>> f *** g


-- | Lift a function to an arrow.
    arr :: (b -> c) -> a b c

-- | Send the first component of the input through the argument
    --   arrow, and copy the rest unchanged to the output.
    first :: a b c -> a (b,d) (c,d)

-}

printInterleaved' sistrs (a:asts) = exactPC a >> printInterleaved sistrs asts
printInterleaved' _ _ = internalError "printInterleaved'"

printStreams :: [(Pos, EP ())] -> [(Pos, EP ())] -> EP ()
printStreams [] ys = printSeq ys
printStreams xs [] = printSeq xs
printStreams (x@(p1,ep1):xs) (y@(p2,ep2):ys)
    | p1 <= p2 = printWhitespace p1 >> ep1 >> printStreams xs (y:ys)
    | otherwise = printWhitespace p2 >> ep2 >> printStreams (x:xs) ys

-- printMerged :: [a] -> [b] -> EP ()
printMerged :: (ExactP a, ExactP b) => [GHC.Located a] -> [GHC.Located b] -> EP ()
printMerged [] [] = return ()
printMerged [] bs = mapM_ exactPC bs
printMerged as [] = mapM_ exactPC as
printMerged (a@(GHC.L l1 _):as) (b@(GHC.L l2 _):bs) =
  if l1 < l2
    then exactPC a >> printMerged    as (b:bs)
    else exactPC b >> printMerged (a:as)   bs

interleave :: [a] -> [a] -> [a]
interleave [] ys = ys
interleave xs [] = xs
interleave (x:xs) (y:ys) = x:y: interleave xs ys

maybeEP :: (a -> EP ()) -> Maybe a -> EP ()
maybeEP = maybe (return ())

-- bracketList :: (ExactP ast) => (String, String, String) -> [GHC.SrcSpan] -> [ast] -> EP ()
bracketList :: (Annotated b1, SrcInfo b, ExactP b1) => (String, String, String) -> [b] -> [b1] -> EP ()
bracketList (a,b,c) poss asts = printInterleaved (pList poss (a,b,c)) asts

pList (p:ps) (a,b,c) = (p,a) : pList' ps (b,c)
pList _ _ = internalError "pList"
pList' [] _ = []
pList' [p] (_,c) = [(p,c)]
pList' (p:ps) (b,c) = (p, b) : pList' ps (b,c)

parenList, squareList, curlyList, parenHashList :: (Annotated ast,ExactP ast) => [GHC.SrcSpan] -> [ast] -> EP ()
parenList = bracketList ("(",",",")")
squareList = bracketList ("[",",","]")
curlyList = bracketList ("{",",","}")
parenHashList = bracketList ("(#",",","#)")

-- layoutList :: (Functor ast, Show (ast ()), ExactP ast) => [GHC.SrcSpan] -> [ast] -> EP ()
layoutList :: (Annotated ast, ExactP ast) => [GHC.SrcSpan] -> [ast] -> EP ()
layoutList poss asts = printStreams
        (map (pos *** printString) $ lList poss)
        (map (pos . ann &&& exactP') asts)
  where
    exactP' ast = do
      ma <- getAnnotation (ann ast)
      exactP ma ast

lList (p:ps) = (if isNullSpan p then (p,"") else (p,"{")) : lList' ps
lList _ = internalError "lList"
lList' [] = []
lList' [p] = [if isNullSpan p then (p,"") else (p,"}")]
lList' (p:ps) = (if isNullSpan p then (p,"") else (p,";")) : lList' ps

printSemi :: GHC.SrcSpan -> EP ()
printSemi p = do
  printWhitespace (pos p)
  when (not $ isNullSpan p) $ printString ";"

-- ---------------------------------------------------------------------

getAnn :: (Annotation -> Bool) -> Maybe [Annotation] -> String -> [Annotation]
getAnn isAnn ma str =
  case ma of
    Nothing -> error $ "getAnn expecting an annotation:" ++ str
    Just as -> filter isAnn as

isAnnGRHS :: Annotation -> Bool
isAnnGRHS an = case an of
  (Ann _ _ (AnnGRHS {})) -> True
  _                     -> False

isAnnMatch :: Annotation -> Bool
isAnnMatch an = case an of
  (Ann _ _ (AnnMatch {})) -> True
  _                       -> False

isAnnHsLet :: Annotation -> Bool
isAnnHsLet an = case an of
  (Ann _ _ (AnnHsLet {})) -> True
  _                     -> False

isAnnHsDo :: Annotation -> Bool
isAnnHsDo an = case an of
  (Ann _ _ (AnnHsDo {})) -> True
  _                      -> False

isAnnHsExplicitTupleTy :: Annotation -> Bool
isAnnHsExplicitTupleTy an = case an of
  (Ann _ _ (AnnHsExplicitTupleTy {})) -> True
  _                                   -> False

isAnnExplicitTuple :: Annotation -> Bool
isAnnExplicitTuple an = case an of
  (Ann _ _ (AnnExplicitTuple {})) -> True
  _                               -> False

isAnnArithSeq :: Annotation -> Bool
isAnnArithSeq an = case an of
  (Ann _ _ (AnnArithSeq {})) -> True
  _                          -> False

isAnnOverLit :: Annotation -> Bool
isAnnOverLit an = case an of
  (Ann _ _ (AnnOverLit {})) -> True
  _                         -> False

isAnnTypeSig :: Annotation -> Bool
isAnnTypeSig an = case an of
  (Ann _ _ (AnnTypeSig {})) -> True
  _                         -> False

isAnnStmtLR :: Annotation -> Bool
isAnnStmtLR an = case an of
  (Ann _ _ (AnnStmtLR {})) -> True
  _                        -> False

isAnnLetStmt :: Annotation -> Bool
isAnnLetStmt an = case an of
  (Ann _ _ (AnnLetStmt {})) -> True
  _                         -> False

isAnnDataDecl :: Annotation -> Bool
isAnnDataDecl an = case an of
  (Ann _ _ (AnnDataDecl {})) -> True
  _                          -> False

isAnnConDecl :: Annotation -> Bool
isAnnConDecl an = case an of
  (Ann _ _ (AnnConDecl {})) -> True
  _                         -> False

isAnnListItem :: Annotation -> Bool
isAnnListItem an = case an of
  (Ann _ _ (AnnListItem {})) -> True
  _                          -> False

isAnnHsFunTy :: Annotation -> Bool
isAnnHsFunTy an = case an of
  (Ann _ _ (AnnHsFunTy {})) -> True
  _                         -> False

isAnnHsForAllTy :: Annotation -> Bool
isAnnHsForAllTy an = case an of
  (Ann _ _ (AnnHsForAllTy {})) -> True
  _                            -> False

isAnnHsParTy :: Annotation -> Bool
isAnnHsParTy an = case an of
  (Ann _ _ (AnnHsParTy {})) -> True
  _                         -> False

isAnnHsTupleTy :: Annotation -> Bool
isAnnHsTupleTy an = case an of
  (Ann _ _ (AnnHsTupleTy {})) -> True
  _                           -> False

isAnnPatBind :: Annotation -> Bool
isAnnPatBind an = case an of
  (Ann _ _ (AnnPatBind {})) -> True
  _                         -> False

isAnnAsPat :: Annotation -> Bool
isAnnAsPat an = case an of
  (Ann _ _ (AnnAsPat {})) -> True
  _                       -> False

isAnnTuplePat :: Annotation -> Bool
isAnnTuplePat an = case an of
  (Ann _ _ (AnnTuplePat {})) -> True
  _                          -> False

--------------------------------------------------
-- Exact printing for GHC

class ExactP ast where
  -- | Print an AST fragment, possibly having an annotation. The
  -- correct position in output is already established.
  exactP :: (Maybe [Annotation]) -> ast -> EP ()

instance ExactP (GHC.HsModule GHC.RdrName) where
  exactP ma (GHC.HsModule Nothing exps imps decls deprecs haddock) = do
    let Just [Ann _ _ (AnnHsModule ep)] = ma
    printSeq $ map (pos . ann &&& exactPC) decls

    -- put the end of file whitespace in
    pe <- getPos
    padUntil (undelta pe ep) `debug` ("exactP.HsModule:(pe,ep)=" ++ show (pe,ep))
    printString ""

  exactP ma (GHC.HsModule (Just lmn@(GHC.L l mn)) mexp imps decls deprecs haddock) = do
    let Just [Ann csm _ (AnnHsModule ep)] = ma

    mAnn <- getAnnotation l
    let p = (1,1)
    case mAnn of
      Just [(Ann cs _ (AnnModuleName pm _pn po pc pw))] -> do
        printStringAt (undelta p pm) "module" `debug` ("exactP.HsModule:cs=" ++ show cs)
        exactPC lmn
        case mexp of
          Just exps -> do
            printStringAt (undelta p po) "("
            mapM_ exactPC exps
            p2 <- getPos
            printStringAt (undelta p2 pc) ")"
          Nothing -> return ()
        printStringAt (undelta p pw) "where"
        mapM_ exactPC imps
      _ -> return ()

    printSeq $ map (pos . ann &&& exactPC) decls

    -- put the end of file whitespace in
    pe <- getPos
    padUntil (undelta pe ep) `debug` ("exactP.HsModule:(pe,ep)=" ++ show (pe,ep))
    printString ""

-- ---------------------------------------------------------------------

instance ExactP (GHC.ModuleName) where
  exactP ma mn = do
    printString (GHC.moduleNameString mn)

-- ---------------------------------------------------------------------

instance ExactP (GHC.IE GHC.RdrName) where
  exactP ma (GHC.IEVar n) = do
    let Just [(Ann cs _ (AnnIEVar mc))] = ma
    p <- getPos
    printString (rdrName2String n)
    printStringAtMaybeDelta mc ","
    return ()

  exactP ma (GHC.IEThingAbs n) = do
    let Just [(Ann cs _ (AnnIEThingAbs mc))] = ma `debug` ("exactP.IEThingAbs:" ++ show ma)
    printString (rdrName2String n)
    printStringAtMaybeDelta mc ","
    return ()

  exactP ma _ = printString ("no exactP for " ++ show (ma))

-- ---------------------------------------------------------------------

instance ExactP (GHC.ImportDecl GHC.RdrName) where
  exactP ma imp = do
    let Just [(Ann cs _ an)] = ma
    p <- getPos
    printString "import"
    printStringAtMaybeDeltaP p (id_qualified an) "qualified"
    exactPC (GHC.ideclName imp)
    printStringAtMaybeDeltaP p (id_as an) "as"
    case GHC.ideclAs imp of
      Nothing -> return ()
      Just mn -> printStringAtMaybeDeltaP p (id_as_pos an) (GHC.moduleNameString mn)
    printStringAtMaybeDeltaP p (id_hiding an) "hiding"
    printStringAtMaybeDeltaP p (id_op an) "("
    case GHC.ideclHiding imp of
      Nothing -> return ()
      Just (_,ies) -> mapM_ exactPC ies
    printStringAtMaybeDelta (id_cp an) ")"

-- ---------------------------------------------------------------------

doMaybe :: (Monad m) => Maybe a -> (a -> m ()) -> m ()
doMaybe ma f = case ma of
                 Nothing -> return ()
                 Just a -> f a

instance ExactP (GHC.HsDecl GHC.RdrName) where
  exactP ma decl = case decl of
    GHC.TyClD d -> exactP ma d
    GHC.InstD d -> printString "InstD"
    GHC.DerivD d -> printString "DerivD"
    GHC.ValD d -> exactP ma d
    GHC.SigD d -> exactP ma d
    GHC.DefD d -> printString "DefD"
    GHC.ForD d -> printString "ForD"
    GHC.WarningD d -> printString "WarningD"
    GHC.AnnD d -> printString "AnnD"
    GHC.RuleD d -> printString "RuleD"
    GHC.VectD d -> printString "VectD"
    GHC.SpliceD d -> printString "SpliceD"
    GHC.DocD d -> printString "DocD"
    GHC.QuasiQuoteD d -> printString "QuasiQuoteD"
    GHC.RoleAnnotD d -> printString "RoleAnnotD"

instance ExactP (GHC.HsBind GHC.RdrName) where
  exactP _ (GHC.FunBind _n _  (GHC.MG matches _ _ _) _fun_co_fn _fvs _tick) = do
    mapM_ exactPC matches

  exactP ma (GHC.PatBind lhs (GHC.GRHSs grhs lb) _ty _fvs _ticks) = do
    let [(Ann _ _ (AnnPatBind eqPos wherePos))] = getAnn isAnnPatBind ma "PatBind"
    exactPC lhs
    printStringAtMaybeDelta eqPos "="
    mapM_ exactPC grhs
    printStringAtMaybeDelta wherePos "where"
    exactP Nothing lb

  exactP ma (GHC.VarBind var_id var_rhs var_inline ) = printString "VarBind"
  exactP ma (GHC.AbsBinds abs_tvs abs_ev_vars abs_exports abs_ev_binds abs_binds) = printString "AbsBinds"
  exactP ma (GHC.PatSynBind patsyn_id bind_fvs patsyn_args patsyn_def patsyn_dir) = printString "PatSynBind"

instance ExactP (GHC.Match GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  exactP ma (GHC.Match pats typ (GHC.GRHSs grhs lb)) = do
    let [(Ann lcs _ (AnnMatch nPos n isInfix eqPos wherePos))] = getAnn isAnnMatch ma "Match"
    if isInfix
      then do
        exactPC (head pats)
        if isSymbolRdrName n
          then printStringAtDelta nPos (rdrName2String n)
          else printStringAtDelta nPos ("`" ++ (rdrName2String n) ++ "`")
        mapM_ exactPC (tail pats)
      else do
        printStringAtDelta nPos (rdrName2String n)
        mapM_ exactPC pats
    printStringAtMaybeDelta eqPos "="
    doMaybe typ exactPC
    mapM_ exactPC grhs
    printStringAtMaybeDelta wherePos "where"
    exactP Nothing lb

instance ExactP (GHC.Pat GHC.RdrName) where
  exactP _  (GHC.VarPat n)     = printString (rdrName2String n)
  exactP ma (GHC.NPat ol _ _)  = exactP ma ol
  exactP _  (GHC.ConPatIn e _) = exactPC e
  exactP _  (GHC.WildPat _)    = printString "_"
  exactP ma (GHC.AsPat n p) = do
    let [(Ann _ _ (AnnAsPat asPos))] = getAnn isAnnAsPat ma "AsPat"
    exactPC n
    printStringAtDelta asPos "@"
    exactPC p

  exactP ma  (GHC.TuplePat pats b _) = do
    let [(Ann _ _ (AnnTuplePat opPos cpPos))] = getAnn isAnnTuplePat ma "TuplePat"
    if b == GHC.Boxed then printStringAtDelta opPos "("
                      else printStringAtDelta opPos "(#"
    mapM_ exactPC pats
    if b == GHC.Boxed then printStringAtDelta cpPos ")"
                      else printStringAtDelta cpPos "#)"

  exactP _ p = printString "Pat"
   `debug` ("exactP.Pat:ignoring " ++ (SYB.showData SYB.Parser 0 p))

instance ExactP (GHC.HsType GHC.RdrName) where
-- HsForAllTy HsExplicitFlag (LHsTyVarBndrs name) (LHsContext name) (LHsType name)
  exactP ma (GHC.HsForAllTy f bndrs ctx typ) = do
    let [(Ann _ _ (AnnHsForAllTy opPos darrowPos cpPos))] = getAnn isAnnHsForAllTy ma "HsForAllTy"
    printStringAtMaybeDelta opPos "("
    exactPC ctx
    printStringAtMaybeDelta cpPos ")"
    printStringAtMaybeDelta darrowPos "=>"
    exactPC typ

  exactP _ (GHC.HsTyVar n) = printString (rdrName2String n)

  exactP _ (GHC.HsAppTy t1 t2) = exactPC t1 >> exactPC t2

  exactP ma (GHC.HsFunTy t1 t2) = do
    let [(Ann _ _ (AnnHsFunTy rarrowPos))] = getAnn isAnnHsFunTy ma "HsFunTy"
    exactPC t1
    printStringAtDelta rarrowPos "->"
    exactPC t2

  exactP ma (GHC.HsParTy t1) = do
    let [(Ann _ _ (AnnHsParTy opPos cpPos))] = getAnn isAnnHsParTy ma "HsParTy"
    printStringAtDelta opPos "("
    exactPC t1
    printStringAtDelta cpPos ")"

  exactP ma (GHC.HsTupleTy sort ts) = do
    let [(Ann _ _ (AnnHsTupleTy opPos cpPos))] = getAnn isAnnHsTupleTy ma "HsTupleTy"
    let (ostr,cstr) = case sort of
          GHC.HsUnboxedTuple -> ("(#","#)")
          _ -> ("(",")")
    printStringAtDelta opPos ostr
    mapM_ exactPC ts
    printStringAtDelta cpPos cstr



{-
HsListTy (LHsType name)	 
HsPArrTy (LHsType name)	 
HsTupleTy HsTupleSort [LHsType name]	 
HsOpTy (LHsType name) (LHsTyOp name) (LHsType name)	 
HsIParamTy HsIPName (LHsType name)	 
HsEqTy (LHsType name) (LHsType name)	 
HsKindSig (LHsType name) (LHsKind name)	 
HsQuasiQuoteTy (HsQuasiQuote name)	 
HsSpliceTy (HsSplice name) PostTcKind	 
HsDocTy (LHsType name) LHsDocString	 
HsBangTy HsBang (LHsType name)	 
HsRecTy [ConDeclField name]	 
HsCoreTy Type	 
HsExplicitListTy PostTcKind [LHsType name]	 
HsExplicitTupleTy [PostTcKind] [LHsType name]	 
HsTyLit HsTyLit	 
HsWrapTy HsTyWrapper (HsType name)
-}

  exactP _ t = printString "HsType" `debug` ("exactP.LHSType:ignoring " ++ (SYB.showData SYB.Parser 0 t))


instance ExactP (GHC.HsContext GHC.RdrName) where
  exactP _ typs = do
    mapM_ exactPC typs

instance ExactP (GHC.GRHS GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  exactP ma (GHC.GRHS guards expr) = do
    let [(Ann lcs _ (AnnGRHS guardPos eqPos))] = getAnn isAnnGRHS ma "GRHS"
    printStringAtMaybeDelta guardPos "|"
    mapM_ exactPC guards
    printStringAtMaybeDelta eqPos "="
    exactPC expr

instance ExactP (GHC.StmtLR GHC.RdrName GHC.RdrName (GHC.LHsExpr GHC.RdrName)) where
  exactP ma (GHC.BodyStmt e _ _ _) = do
    let [(Ann lcs _ an)] = getAnn isAnnStmtLR ma "StmtLR"
    exactPC e

  exactP ma (GHC.LetStmt lb) = do
    let [(Ann lcs _ an)] = getAnn isAnnLetStmt ma "LetStmt"
    p <- getPos
    printStringAtMaybeDelta (ls_let an) "let" `debug` ("exactP.LetStmt:an=" ++ show an)
    exactP Nothing lb
    printStringAtMaybeDeltaP p (ls_in an) "in"


  exactP _ _ = printString "StmtLR"

instance ExactP (GHC.HsExpr GHC.RdrName) where
  exactP ma  (GHC.HsLet lb e)    = do
    let [(Ann lcs _ an)] = getAnn isAnnHsLet ma "HsLet"
    p <- getPos
    printStringAtMaybeDelta (hsl_let an) "let" `debug` ("exactP.HsLet:an=" ++ show an)
    exactP Nothing lb
    printStringAtMaybeDeltaP p (hsl_in an) "in"
    exactPC e
  exactP ma  (GHC.HsDo cts stmts _typ)    = do
    let [(Ann lcs _ an)] = getAnn isAnnHsDo ma "HsDo"
    printStringAtMaybeDelta (hsd_do an) "do" `debug` ("exactP.HsDo:an=" ++ show an)
    mapM_ exactPC stmts
  exactP ma (GHC.HsOverLit lit) = exactP ma lit -- `debug` ("GHC.HsOverLit:" ++ show ma)
  exactP _  (GHC.OpApp e1 op _f e2) = exactPC e1 >> exactPC op >> exactPC e2
  exactP ma  (GHC.HsVar v)          = exactP ma v
 -- ExplicitTuple [HsTupArg id] Boxity
  exactP ma (GHC.ExplicitTuple args b) = do
    let [(Ann lcs _ an)] = getAnn isAnnExplicitTuple ma "ExplicitTuple"
    if b == GHC.Boxed then printStringAtDelta (et_opos an) "("
                      else printStringAtDelta (et_opos an) "(#"
    mapM_ (exactP Nothing) args `debug` ("exactP.ExplicitTuple")
    if b == GHC.Boxed then printStringAtDelta (et_cpos an) ")"
                      else printStringAtDelta (et_cpos an) "#)"

  exactP _  (GHC.HsApp e1 e2) = exactPC e1 >> exactPC e2

  exactP ma (GHC.ArithSeq _ _ seqInfo) = do
    let [(Ann lcs _ (AnnArithSeq obPos mcPos ddPos cbPos))] = getAnn isAnnArithSeq ma "ArithSeq"
    printStringAtDelta obPos "["
    case seqInfo of
      GHC.From e1 -> exactPC e1 >> printStringAtDelta ddPos ".."
      GHC.FromTo e1 e2 -> do
        exactPC e1
        printStringAtDelta ddPos ".."
        exactPC e2
      GHC.FromThen e1 e2 -> do
        exactPC e1
        printStringAtMaybeDelta mcPos ","
        exactPC e2
        printStringAtDelta ddPos ".."
      GHC.FromThenTo e1 e2 e3 -> do
        exactPC e1
        printStringAtMaybeDelta mcPos ","
        exactPC e2
        printStringAtDelta ddPos ".."
        exactPC e3

    printStringAtDelta cbPos "]"

  exactP _ e = printString "HsExpr"
    `debug` ("exactP.HsExpr:not processing " ++ (SYB.showData SYB.Parser 0 e) )

instance ExactP GHC.RdrName where
  exactP Nothing n = printString (rdrName2String n)

  exactP ma@(Just _) n = do
    printString (rdrName2String n)
    -- printListCommaMaybe ma

instance ExactP (GHC.HsTupArg GHC.RdrName) where
  exactP _ (GHC.Missing _) = return ()
  exactP _ (GHC.Present e) = exactPC e

instance ExactP (GHC.HsLocalBinds GHC.RdrName) where
  exactP _ (GHC.HsValBinds (GHC.ValBindsIn binds sigs)) = do
    printMerged (GHC.bagToList binds) sigs
  exactP _ (GHC.HsValBinds (GHC.ValBindsOut binds sigs)) = printString "ValBindsOut"
  exactP _ (GHC.HsIPBinds binds) = printString "HsIPBinds"
  exactP _ (GHC.EmptyLocalBinds) = return ()


instance ExactP (GHC.Sig GHC.RdrName) where
  exactP ma (GHC.TypeSig lns typ) = do
    let [(Ann _ _ (AnnTypeSig dc))] = getAnn isAnnTypeSig ma "TypeSig"
    mapM_ exactPC lns
    printStringAtDelta dc "::"
    exactPC typ

  exactP _ _ = printString "Sig"

instance ExactP (GHC.HsOverLit GHC.RdrName) where
  -- exactP (Just [(Ann cs p an)]) _ = printString (ol_str an)
  exactP a@(Just as) _ = printString (ol_str an)
    where [(Ann cs _ an)] = getAnn isAnnOverLit a "OverLit"
  exactP Nothing            lit = printString "overlit no ann"

instance ExactP GHC.HsLit where
  exactP ma lit = case lit of
    GHC.HsChar       rw -> printString ('\'':rw:"\'")
{-
    String     _ _ rw -> printString ('\"':rw ++ "\"")
    Int        _ _ rw -> printString (rw)
    Frac       _ _ rw -> printString (rw)
    PrimInt    _ _ rw -> printString (rw ++ "#" )
    PrimWord   _ _ rw -> printString (rw ++ "##")
    PrimFloat  _ _ rw -> printString (rw ++ "#" )
    PrimDouble _ _ rw -> printString (rw ++ "##")
    PrimChar   _ _ rw -> printString ('\'':rw ++ "\'#" )
    PrimString _ _ rw -> printString ('\"':rw ++ "\"#" )
-}

{-
data HsLit
  = HsChar	    Char		-- Character
  | HsCharPrim	    Char		-- Unboxed character
  | HsString	    FastString		-- String
  | HsStringPrim    FastString		-- Packed string
  | HsInt	    Integer		-- Genuinely an Int; arises from TcGenDeriv, 
					--	and from TRANSLATION
  | HsIntPrim       Integer             -- literal Int#
  | HsWordPrim      Integer             -- literal Word#
  | HsInt64Prim     Integer             -- literal Int64#
  | HsWord64Prim    Integer             -- literal Word64#
  | HsInteger	    Integer  Type	-- Genuinely an integer; arises only from TRANSLATION
					-- 	(overloaded literals are done with HsOverLit)
  | HsRat	    FractionalLit Type	-- Genuinely a rational; arises only from TRANSLATION
					-- 	(overloaded literals are done with HsOverLit)
  | HsFloatPrim	    FractionalLit	-- Unboxed Float
  | HsDoublePrim    FractionalLit	-- Unboxed Double
  deriving (Data, Typeable)
-}



instance ExactP (GHC.TyClDecl GHC.RdrName) where
  exactP ma (GHC.ForeignType _ _)    = printString "ForeignType"
  exactP ma (GHC.FamDecl  _)         = printString "FamDecl"
  exactP ma (GHC.SynDecl  _ _ _ _)   = printString "SynDecl"

  exactP ma (GHC.DataDecl ln (GHC.HsQTvs ns tyVars) defn _) = do
    let [(Ann lcs _ (AnnDataDecl eqDelta))] = getAnn isAnnDataDecl ma "DataDecl"
    printString "data"
    exactPC ln
    printStringAtDelta eqDelta "="
    mapM_ exactPC tyVars
    exactP ma defn


  exactP ma (GHC.ClassDecl  _ _ _ _ _ _ _ _ _ _) = printString "ClassDecl"

-- ---------------------------------------------------------------------

instance ExactP (GHC.HsTyVarBndr GHC.RdrName) where
  exactP _ _ = printString "HsTyVarBndr"

-- ---------------------------------------------------------------------

instance ExactP (GHC.HsDataDefn GHC.RdrName) where
  exactP _ (GHC.HsDataDefn nOrD ctx mtyp mkind cons mderivs) = do
    mapM_ exactPC cons

-- ---------------------------------------------------------------------

instance ExactP (GHC.ConDecl GHC.RdrName) where
  exactP ma (GHC.ConDecl ln exp qvars ctx dets res _ _) = do
    let [(Ann lcs _ (AnnConDecl mp))] = getAnn isAnnConDecl ma "ConDecl"
    exactPC ln
    printStringAtMaybeDelta mp "|"


-- ---------------------------------------------------------------------

-- Hopefully, this will never fire.
-- If it does, hopefully by that time https://github.com/sol/rewrite-with-location
-- will be implemented.
-- If not, then removing all calls to internalError should give a better
-- idea where the error comes from.
-- So far, it's necessary to eliminate non-exhaustive patterns warnings.
-- We don't want to turn them off, as we want unhandled AST nodes to be
-- reported.
internalError :: String -> a
internalError loc = error $ unlines
    [ "haskell-src-exts: ExactPrint: internal error (non-exhaustive pattern)"
    , "Location: " ++ loc
    , "This is either caused by supplying incorrect location information or by"
    , "a bug in haskell-src-exts. If this happens on an unmodified AST obtained"
    , "by the haskell-src-exts Parser it is a bug, please it report it at"
    , "https://github.com/haskell-suite/haskell-src-exts"]


