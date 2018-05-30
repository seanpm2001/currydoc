module CurryDoc.Comment where

import CurryDoc.Span
import CurryDoc.SpanInfo
import CurryDoc.Type
import CurryDoc.Ident

import List

data Comment = NestedComment String
             | LineComment   String
  deriving (Eq, Ord, Read, Show)

data CDocComment = Pre  { comment :: Comment }
                 | Post { comment :: Comment }
                 | None { comment :: Comment }
  deriving Show

isPre, isPost, isNone :: CDocComment -> Bool
isPre  Pre  {} = True
isPre  Post {} = False
isPre  None {} = False

isPost Pre  {} = False
isPost Post {} = True
isPost None {} = False

isNone Pre  {} = False
isNone Post {} = False
isNone None {} = True


data CommentedDecl
  = CommentedTypeDecl Ident [Comment]
  | CommentedDataDecl Ident [Comment] [(Ident, [Comment])]
  | CommentedNewtypeDecl Ident [Comment] [Comment]
  | CommentedClassDecl Ident [Comment] [CommentedDecl]
  | CommentedInstanceDecl QualIdent InstanceType [Comment] [CommentedDecl]
  | CommentedFunctionDecl Ident [Comment]
  | CommentedTypeSig [Ident] [Comment] [(TypeExpr, [Comment])]
  deriving Show


readCommentFile :: String -> IO [(Span, Comment)]
readCommentFile s = readFile s >>= (return . read)

readASTFile :: String -> IO (Module ())
readASTFile s = readFile s >>= (return . read)

associateCurryDoc :: [(Span, Comment)] -> Module a -> ([CommentedDecl], [Comment])
associateCurryDoc []       _                       = ([], [])
associateCurryDoc xs@(_:_) (Module spi _ _ _ _ ds) =
  let (rest, result) = associateCurryDocHeader spi sp xs'
  in  (merge $ associateCurryDocDecls rest ds Nothing, result)
  where xs' = map (\(sp',c) -> (sp', classifyComment c)) xs
        sp = case ds of
          (d:_) -> getSrcSpan d
          _     -> NoSpan

associateCurryDocHeader :: SpanInfo                           -- ^ module SpanInfo
                        -> Span                               -- ^ first decl span
                        -> [(Span, CDocComment)]              -- ^ to be matched
                        -> ([(Span, CDocComment)], [Comment]) -- ^ (rest, matched)
associateCurryDocHeader spi@(SpanInfo _ (spm : ss)) sp (c:cs) =
  case c of
    (sp', Pre  c') | vertDist sp' spm >= 0 ->
      let (match, next)   = getToMatch spm sp' cs isPre
          (rest, matched) = associateCurryDocHeader spi sp next
      in (rest, c' : ((map (comment . snd) match) ++ matched))
                   | otherwise             ->
      let (rest, matched) = associateCurryDocHeader spi sp cs
      in (c:rest, matched)

    (sp', Post c') | (vertDist sp' sp  >= 1
                       || isNoSpan sp) &&
                     isAfter sp' (last ss) ->
      let (match, next)   = getToMatch sp sp' cs isPost
          (rest, matched) = associateCurryDocHeader spi sp next
      in (rest, c' : ((map (comment . snd) match) ++ matched))
                   | otherwise             ->
      (c:cs, [])

    (_  , None _)                          ->
      associateCurryDocHeader spi sp cs
associateCurryDocHeader (SpanInfo _ []) _ (c:cs) = (c:cs, [])
associateCurryDocHeader NoSpanInfo      _ (c:cs) = (c:cs, [])
associateCurryDocHeader _               _ []     = ([]  , [])

associateCurryDocDecls :: [(Span, CDocComment)]
                       -> [Decl a]
                       -> Maybe (Decl a)
                       -> [CommentedDecl]
associateCurryDocDecls []               _      _    = []
associateCurryDocDecls (c         : cs) []     prev = matchLast (c:cs) prev
associateCurryDocDecls ((sp, cdc) : cs) (d:ds) prev =
  case cdc of
    Pre  _ | vertDist sp spd >= 0 ->
               let (match, next) = getToMatch spd sp cs isPre
               in  associateCurryDocDeclPre ((sp, cdc) : match) d
                     : associateCurryDocDecls next (d:ds) (Just d)
           | otherwise ->
               associateCurryDocDecls ((sp, cdc) : cs) ds (Just d)

    Post _ | vertDist sp spd >= 1 ->
               case prev of
                 Nothing -> associateCurryDocDecls cs (d:ds) prev
                 Just d' -> let (match, next) = getToMatch spd sp cs isPost
                            in  associateCurryDocDeclPost ((sp, cdc) : match) d'
                                  : associateCurryDocDecls next (d:ds) prev
           | vertDist sp spd == 0 ->
               let (match, next) = getToMatch spd sp cs isPost
               in  associateCurryDocDeclPost ((sp, cdc) : match) d
                     : associateCurryDocDecls next (d:ds) prev
           | otherwise ->
               associateCurryDocDecls ((sp, cdc) : cs) ds (Just d)

    None _ -> associateCurryDocDecls cs (d:ds) prev
  where spd  = getSrcSpan d

getToMatch :: Span                  -- ^ until
           -> Span                  -- ^ last undiscarded comment span
           -> [(Span, CDocComment)] -- ^ next comments
           -> (CDocComment -> Bool) -- ^ predicate to test for right comment type
           -> ([(Span, CDocComment)], [(Span, CDocComment)])
getToMatch _    _    []             _ = ([], [])
getToMatch stop last ((sp, c) : cs) p =
  if (vertDist sp stop >= 0 || isNoSpan stop)           -- pos is ok
       && (p c || (isNone c && vertDist last sp <= 1))  -- CDocType is ok
    then add (sp, c) (getToMatch stop sp cs p)
    else ([], (sp, c) : cs)
  where add x (xs, rest) = (x:xs, rest)

matchLast :: [(Span, CDocComment)]
          -> Maybe (Decl a)
          -> [CommentedDecl]
matchLast []                  (Just _) = []
matchLast _                   Nothing  = []
matchLast ((sp, Post c) : cs) (Just d) =
  let (match, next) = getToMatch (getSrcSpan d) sp cs isPre
  in  associateCurryDocDeclPre ((sp, Post c) : match) d
        : matchLast next (Just d)
matchLast ((_ , None _) : cs) (Just d) = matchLast cs (Just d)
matchLast ((_ , Pre  _) : cs) (Just d) = matchLast cs (Just d)

associateCurryDocDeclPre :: [(Span, CDocComment)]
                         -> Decl a
                         -> CommentedDecl
associateCurryDocDeclPre xs d@(FunctionDecl _ _ f _) =
  let (match, _) = getToMatch d (fst (first xs)) xs isPre
  CommentedFunctionDecl f match []
associateCurryDocDeclPre xs (ClassDecl spi _ f _ ds) =
  let (rest, result) = associateCurryDocHeader spi sp xs
  in  CommentedClassDecl f result (associateCurryDocDecls rest ds Nothing)
  where sp = case ds of
          (d:_) -> getSrcSpan d
          _     -> NoSpan
associateCurryDocDeclPre xs (InstanceDecl spi _ f ty ds) =
  let (rest, result) = associateCurryDocHeader spi sp xs
  in  CommentedInstanceDecl f ty result (associateCurryDocDecls rest ds Nothing)
  where sp = case ds of
          (d:_) -> getSrcSpan d
          _     -> NoSpan
associateCurryDocDeclPre xs d@(TypeDecl _ f _ _  ) =
  let (match, _) = getToMatch d (fst (first xs)) xs isPre
  CommentedTypeDecl f match []
associateCurryDocDeclPre xs (NewtypeDecl _ f _ c _) =
  let (match, rest) = getToMatch (getSrcSpan c) (fst (first xs)) xs isPre
  in CommentedNewtypeDecl f match rest
associateCurryDocDeclPre xs d@(DataDecl _ f _ [] _) =
  let (match, _) = getToMatch d (fst (first xs)) xs isPre
  CommentedDataDecl f match []
associateCurryDocDeclPre xs d@(DataDecl _ f _ (c:cs) _) =
  let (match, rest) = getToMatch d (fst (first xs)) xs isPre
  CommentedDataDecl f match (matchConstructorsPre (c:cs) rest)
associateCurryDocDeclPre xs d@(TypeSig _ f _ (QualTypeExpr _ _ ty) _) =
  let (match, rest) = getToMatch d (fst (first xs)) xs isPre
  CommentedTypeSig f match (matchArgumentsPre ty rest)

-- TODO data  Y {-| lol -} a =  Z should be invalid

matchArgumentsPre = error "undefined"
matchConstructorsPre = error "undefined"

associateCurryDocDeclPost :: [(Span, CDocComment)]
                          -> Decl a
                          -> CommentedDecl
associateCurryDocDeclPost = error "undefined"

-- relies on the fact that for subsequent entries of the same decl,
-- all comments in the first are before the comments of the second and vice versa
merge :: [CommentedDecl] -> [CommentedDecl]
merge []                                 = []
merge [x]                                = [x]
merge (x1:x2:xs) = case (x1, x2) of
   (CommentedTypeDecl f1 ys1, CommentedTypeDecl f2 ys2)
     | f1 == f2 -> merge (CommentedTypeDecl f1 (ys1 ++ ys2) : xs)
   (CommentedDataDecl f1 ys1 cs1, CommentedDataDecl f2 ys2 cs2)
     | f1 == f2 -> merge (CommentedDataDecl f1 (ys1 ++ ys2)
                                               (zipWith zipF cs1 cs2) : xs)
   (CommentedNewtypeDecl f1 ys1 (c, cc1), CommentedNewtypeDecl f2 ys2 (_, cc2))
     | f1 == f2 -> merge (CommentedNewtypeDecl f1 (ys1 ++ ys2)
                                                  (c, (cc1 ++ cc2)) : xs)
   (CommentedFunctionDecl f1 ys1, CommentedFunctionDecl f2 ys2)
     | f1 == f2 -> merge (CommentedFunctionDecl f1 (ys1 ++ ys2) : xs)
   (CommentedTypeSig f1 ys1 ps1, CommentedTypeSig f2 ys2 ps2)
     | f1 == f2 -> merge (CommentedTypeSig f1 (ys1 ++ ys2)
                                              (zipWith zipF ps1 ps2) : xs)
   (CommentedClassDecl f1 ys1 ds1, CommentedClassDecl f2 ys2 ds2)
     | f1 == f2 -> merge (CommentedClassDecl f1 (ys1 ++ ys2)
                                                (merge (ds1 ++ ds2)) : xs)
   (CommentedInstanceDecl f1 ty1 ys1 ds1, CommentedInstanceDecl f2 ty2 ys2 ds2)
     | ty1 == ty2 &&
       f1 == f2 -> merge (CommentedInstanceDecl f1 ty1 (ys1 ++ ys2)
                                                       (merge (ds1 ++ ds2)) : xs)
   _ -> x1 : merge (x2 : xs)

  where zipF (a, b) (c, d) | a == c    = (a, b ++ d)
                           | otherwise = error ("Comment.merge.zipF: " ++ show a
                                                   ++ ", " ++ show c)


classifyComment :: Comment -> CDocComment
classifyComment c@(NestedComment s) | "{- |" `isPrefixOf` s = Pre  c
                                    | "{- ^" `isPrefixOf` s = Post c
                                    | otherwise             = None c
classifyComment c@(LineComment   s) | "-- |" `isPrefixOf` s = Pre  c
                                    | "-- ^" `isPrefixOf` s = Post c
                                    | otherwise             = None c
