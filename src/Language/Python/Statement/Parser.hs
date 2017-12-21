{-# language FlexibleContexts #-}
module Language.Python.Statement.Parser where

import Papa hiding (Sum, Product)
import Control.Monad.State
import Data.DList (DList)
import Data.Functor.Compose
import Data.Functor.Product
import Data.Functor.Sum
import Data.Separated.Before (Before(..))
import Text.Parser.LookAhead
import Text.Trifecta hiding (Unspaced(..), comma, dot, colon)
import Language.Python.AST.Symbols
import Language.Python.Expr.Parser
import Language.Python.Parser.ArgsList
import Language.Python.Parser.ArgumentList
import Language.Python.Parser.Combinators
import Language.Python.Parser.Comment
import Language.Python.Parser.DottedName
import Language.Python.Parser.Identifier
import Language.Python.Parser.Keywords
import Language.Python.Parser.SrcInfo
import Language.Python.Parser.Symbols
import Language.Python.Parser.TestlistStarExpr
import Language.Python.Statement.IR
import Language.Python.Statement.Parser.AugAssign
import Language.Python.Statement.Parser.Imports

import qualified Data.DList as DList
import qualified Data.List.NonEmpty as NonEmpty

import Text.Parser.Unspaced

statement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (Statement SrcInfo)
statement =
  annotated $
  (StatementSimple <$> simpleStatement) <|>
  (StatementCompound <$> compoundStatement)

simpleStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (SimpleStatement SrcInfo)
simpleStatement =
  annotated $
  SimpleStatement <$>
  smallStatement <*>
  manyF (try $ beforeF (betweenWhitespace semicolon) smallStatement) <*>
  optional (try $ whitespaceBefore semicolon) <*>
  whitespaceBefore newlineChar

smallStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (SmallStatement SrcInfo)
smallStatement =
  annotated $
  smallStatementExpr <|>
  smallStatementDel <|>
  smallStatementPass <|>
  smallStatementFlow <|>
  smallStatementImport <|>
  smallStatementGlobal <|>
  smallStatementNonlocal <|>
  smallStatementAssert
  where
    augAssignSequence =
      beforeF
        (betweenWhitespace augAssign)
        ((InL <$> try yieldExpr) <|>
         (InR <$> testList))

    regularAssignSequence =
      manyF
        (beforeF
          (betweenWhitespace equals)
          ((InL <$> try yieldExpr) <|> (InR <$> testlistStarExpr test starExpr)))

    smallStatementExpr =
      SmallStatementExpr <$>
      testlistStarExpr test starExpr <*>
      ((InL <$> try augAssignSequence) <|>
       (InR <$> regularAssignSequence))

    smallStatementDel =
      SmallStatementDel <$>
      (string "del" *>
       whitespaceBefore1F exprList)

    smallStatementPass =
      string "pass" $>
      SmallStatementPass

    smallStatementFlow =
      SmallStatementFlow <$>
      flowStatement

    smallStatementImport =
      SmallStatementImport <$>
      importStatement

    smallStatementGlobal =
      SmallStatementGlobal <$>
      (string "global" *>
       whitespaceBefore1F identifier) <*>
      manyF (beforeF (betweenWhitespace comma) identifier)

    smallStatementNonlocal =
      SmallStatementNonlocal <$>
      (string "nonlocal" *>
       whitespaceBefore1F identifier) <*>
      manyF (beforeF (betweenWhitespace comma) identifier)

    smallStatementAssert =
      SmallStatementAssert <$>
      (string "assert" *>
       whitespaceBefore1F test) <*>
      optionalF (beforeF (betweenWhitespace comma) test)

flowStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (FlowStatement SrcInfo)
flowStatement =
  annotated $
  (symbol "break" $> FlowStatementBreak) <|>
  (symbol "continue" $> FlowStatementContinue) <|>
  (FlowStatementReturn <$>
    (symbol "return" *>
    optionalF (try $ whitespaceBefore1F testList))) <|>
  (FlowStatementRaise <$>
    (symbol "raise" *>
    optionalF (try $ whitespaceBefore1F raiseStatement))) <|>
  (FlowStatementYield <$> yieldExpr)

raiseStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (RaiseStatement SrcInfo)
raiseStatement =
  annotated $
  RaiseStatement <$>
  test <*>
  optionalF (try . beforeF kFrom $ whitespaceBefore1F test)

compoundStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (CompoundStatement SrcInfo)
compoundStatement =
  annotated $
  (CompoundStatementIf <$> ifStatement) <|>
  (CompoundStatementWhile <$> whileStatement) <|>
  (CompoundStatementFor <$> forStatement) <|>
  (CompoundStatementTry <$> tryStatement) <|>
  (CompoundStatementWith <$> withStatement) <|>
  (CompoundStatementFuncDef <$> funcDef) <|>
  (CompoundStatementClassDef <$> classDef) <|>
  (CompoundStatementDecorated <$> decorated) <|>
  (CompoundStatementAsync <$> asyncStatement)

asyncStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (AsyncStatement SrcInfo)
asyncStatement =
  annotated $
  AsyncStatement <$>
  (string "async" *>
   whitespaceBefore1F
     ((InL . InL <$> try funcDef) <|>
      (InL . InR <$> try withStatement) <|>
      (InR <$> forStatement)))

asyncFuncDef
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (AsyncFuncDef SrcInfo)
asyncFuncDef =
  annotated $
  AsyncFuncDef <$>
  (string "async" *>
   whitespaceBefore1F funcDef)

decorator
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (Decorator SrcInfo)
decorator =
  annotated $
  Decorator <$>
  (char '@' *>
   whitespaceBeforeF dottedName) <*>
  optionalF (try . betweenWhitespaceF . optionalF $ try (argumentList identifier test)) <*>
  newlineChar

decorated
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (Decorated SrcInfo)
decorated =
  annotated $
  Decorated <$>
  some1F decorator <*>
  ((InL . InL <$> try classDef) <|>
   (InL . InR <$> try funcDef) <|>
   (InR <$> asyncFuncDef))

classDef
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (ClassDef SrcInfo)
classDef =
  annotated $
  ClassDef <$>
  (string "class" *>
   whitespaceBefore1F identifier) <*>
  optionalF
    (try .
     whitespaceBeforeF .
     parens .
     betweenWhitespaceF .
     optionalF $
     try (argumentList identifier test)) <*>
  beforeF (betweenWhitespace colon) suite

typedArg
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (TypedArg SrcInfo)
typedArg =
  annotated $
  TypedArg <$>
  identifier <*>
  optionalF (try $ beforeF (betweenWhitespace colon) test)

parameters
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (Parameters SrcInfo)
parameters =
  annotated $
  Parameters <$>
  parens
  (betweenWhitespaceF (optionalF . try $ argsList test typedArg))

funcDef
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (FuncDef SrcInfo)
funcDef =
  annotated $
  FuncDef <$>
  (string "def" *>
   whitespaceBefore1F identifier) <*>
  whitespaceBeforeF parameters <*>
  optionalF (try $ beforeF (betweenWhitespace rightArrow) test) <*>
  beforeF (betweenWhitespace colon) suite

withItem
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (WithItem SrcInfo)
withItem =
  annotated $
  WithItem <$>
  test <*>
  optionalF (try $ beforeF (betweenWhitespace1 kAs) expr)

withStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (WithStatement SrcInfo)
withStatement =
  annotated $
  WithStatement <$>
  (string "with" *>
   whitespaceBefore1F withItem) <*>
  manyF (beforeF (betweenWhitespace comma) withItem) <*>
  beforeF (betweenWhitespace colon) suite

exceptClause
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (ExceptClause SrcInfo)
exceptClause =
  annotated $
  ExceptClause <$>
  (try (level *> string "except") *>
   optionalF
     (try . whitespaceBefore1F $
       Pair <$>
       test <*>
       optionalF
         (try $ beforeF (betweenWhitespace1 kAs) identifier)))

tryStatement
  :: ( DeltaParsing m
     , LookAheadParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (TryStatement SrcInfo)
tryStatement =
  annotated $
  try tryStatementExcepts <|>
  tryStatementFinally
  where
    tryStatementExcepts =
      TryStatementExcepts <$>
      (string "try" *>
       beforeF (betweenWhitespace colon) suite) <*>
      some1F
        (Pair <$>
         exceptClause <*>
         beforeF (betweenWhitespace colon) suite) <*>
      optionalF
        (try (level *> string "else") *> beforeF (betweenWhitespace colon) suite) <*>
      optionalF
        (try (level *> string "finally") *> beforeF (betweenWhitespace colon) suite)
    tryStatementFinally =
      TryStatementFinally <$>
      (string "try" *>
       beforeF (betweenWhitespace colon) suite) <*>
       (try (level *> string "finally") *>
        beforeF (betweenWhitespace colon) suite)

whileStatement
  :: ( DeltaParsing m
     , LookAheadParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (WhileStatement SrcInfo)
whileStatement =
  annotated $
  WhileStatement <$>
  (string "while" *>
   whitespaceBefore1F test) <*>
  beforeF (betweenWhitespace colon) suite <*>
  optionalF
    (try (level *> string "else") *>
     beforeF (betweenWhitespace colon) suite)

forStatement
  :: ( DeltaParsing m
     , LookAheadParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (ForStatement SrcInfo)
forStatement =
  annotated $
  ForStatement <$>
  (string "for" *>
   betweenWhitespace1F (testlistStarExpr expr starExpr)) <*>
  (string "in" *>
   whitespaceBefore1F testList) <*>
  beforeF (betweenWhitespace colon) suite <*>
  optionalF
    (try (level *> string "else") *>
     beforeF (betweenWhitespace colon) suite)

ifStatement
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (IfStatement SrcInfo)
ifStatement =
  annotated $
  IfStatement <$>
  (string "if" *>
   whitespaceBefore1F test) <*>
  beforeF (betweenWhitespace colon) suite <*>
  manyF
    (try (level *> string "elif") *>
     (Pair <$>
      whitespaceBefore1F test <*>
      beforeF (betweenWhitespace colon) suite)) <*>
  optionalF
    (try (level *> string "else") *>
     beforeF (betweenWhitespace colon) suite)

indentations
  :: (Traversable t, CharParsing m)
  => t (NonEmpty IndentationChar)
  -> m ()
indentations is = traverseOf_ (traverse.traverse) indentParser is
  where
    indentParser IndentSpace = void $ char ' '
    indentParser IndentTab = void $ char '\t'
    indentParser (IndentContinued nl is) =
      void $
      string (case nl of; CR -> "\r"; LF -> "\n"; CRLF -> "\r\n") *>
      traverse indentParser is

level
  :: DeltaParsing m
  => Unspaced (StateT [NonEmpty IndentationChar] m) [IndentationChar]
level = do
  is <- lift get
  indentations is
  pure (foldMap NonEmpty.toList is) <?> "level indentation (possibly none)"

level1
  :: DeltaParsing m
  => Unspaced (StateT [NonEmpty IndentationChar] m) (NonEmpty IndentationChar)
level1 = (do
  is <- lift get
  indentations is
  case is of
    [] -> empty
    (x:xs) -> pure $ fold1 (x:|xs)) <?> "level indentation"

indent
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced (StateT [NonEmpty IndentationChar] m) ()
indent = (do
  is' <- lookAhead $ level *> some1 indentationChar
  lift $ modify (++ [is'])) <?> "indent"

dedent :: (MonadTrans t, MonadState [a] m) => t m ()
dedent = lift $ modify (fromMaybe [] . init)

suite
  :: ( LookAheadParsing m
     , DeltaParsing m
     )
  => Unspaced (StateT [NonEmpty IndentationChar] m) (Suite SrcInfo)
suite = annotated $ try suiteSingle <|> suiteMulti
  where
    suiteSingle =
      SuiteSingle <$>
      simpleStatement

    suiteMulti =
      SuiteMulti <$>
      (newlineChar <* indent) <*>
      (suiteStatements <* dedent)

    suiteStatements =
      some1F
        (try (InL <$> whitespaceBeforeF (afterF newlineChar comment)) <|>
         (InR <$> beforeF (try level1) statement))
