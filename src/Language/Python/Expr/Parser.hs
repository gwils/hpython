-- from https://docs.python.org/3.5/reference/grammar.html
-- `test` is the production for an expression

{-# language ConstraintKinds #-}
{-# language DataKinds #-}
{-# language FlexibleContexts #-}
{-# language FlexibleInstances #-}
{-# language MultiParamTypeClasses #-}
{-# language TypeFamilies #-}
module Language.Python.Expr.Parser where

import GHC.Stack

import Papa hiding (Space, zero, o, Plus, (\\), Product, argument)
import Data.Functor.Compose
import Data.Functor.Product
import Data.Functor.Sum
import Data.Separated.After (After(..))
import Data.Separated.Before (Before(..))
import Text.Parser.LookAhead
import Text.Trifecta as P hiding
  (Unspaced(..), stringLiteral, integer, octDigit, hexDigit, comma, colon, between)

import Language.Python.AST.Symbols as S
import Language.Python.AST.Keywords
import Language.Python.Expr.AST.BytesLiteral
import Language.Python.Expr.AST.BytesPrefix
import Language.Python.Expr.AST.CompOperator
import Language.Python.Expr.AST.Digits
import Language.Python.Expr.AST.FactorOperator
import Language.Python.Expr.AST.Float
import Language.Python.Expr.AST.Imag
import Language.Python.Expr.AST.Integer
import Language.Python.Expr.AST.LongBytes
import Language.Python.Expr.AST.LongBytesChar
import Language.Python.Expr.AST.LongString
import Language.Python.Expr.AST.LongStringChar
import Language.Python.Expr.AST.ShortBytes
import Language.Python.Expr.AST.ShortBytesChar
import Language.Python.Expr.AST.ShortString
import Language.Python.Expr.AST.ShortStringChar
import Language.Python.Expr.AST.StringLiteral
import Language.Python.Expr.AST.StringPrefix
import Language.Python.Expr.AST.TermOperator
import Language.Python.Expr.IR
import Language.Python.Expr.Parser.StringContent
import Language.Python.Parser.ArgsList
import Language.Python.Parser.ArgumentList
import Language.Python.Parser.Combinators
import Language.Python.Parser.Identifier
import Language.Python.Parser.Keywords
import Language.Python.Parser.SrcInfo
import Language.Python.Parser.Symbols

import Text.Parser.Unspaced

ifThenElse
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (IfThenElse ws SrcInfo)
ifThenElse ws =
  IfThenElse <$>
  after1 ws kIf <*>
  orTest ws <*>
  between'1 ws (string "else" $> KElse) <*>
  test ws

test
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Test ws SrcInfo)
test ws = testCond <|> testLambdef
  where
    testLambdef = annotated $ TestLambdef <$> lambdef ws
    testCond =
      annotated $
      TestCond <$>
      orTest ws <*>
      optionalF (beforeF (try $ some1 ws <* lookAhead kIf) $ ifThenElse ws)

lambdef
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Lambdef ws SrcInfo)
lambdef ws =
  annotated $
  Lambdef <$>
  (string "lambda" *>
   optionalF (before1F ws $ argsList ws (test ws) identifier)) <*>
  beforeF (between' (many ws) colon) (test ws)

orTest
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (OrTest ws SrcInfo)
orTest ws =
  annotated $
  OrTest <$>
  andTest ws <*>
  manyF (beforeF (try $ between'1 ws kOr) (andTest ws))

lambdefNocond
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (LambdefNocond ws SrcInfo)
lambdefNocond ws =
  annotated $
  string "lambda" *>
  (LambdefNocond <$>
   optionalF
     (betweenF
       (some1 ws)
       (many ws)
       (argsList ws (test ws) identifier)) <*>
   beforeF (string ":" *> many ws) (testNocond ws))

testNocond
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (TestNocond ws SrcInfo)
testNocond ws =
  annotated $
  TestNocond <$> ((InL <$> orTest ws) <|> (InR <$> lambdefNocond ws))

compIf
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (CompIf ws SrcInfo)
compIf ws =
  annotated $
  CompIf <$>
  try (between'1 ws kIf) <*>
  testNocond ws <*>
  optionalF (compIter ws)

compIter
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (CompIter ws SrcInfo)
compIter ws =
  annotated $
  CompIter <$> ((InL <$> compFor ws) <|> (InR <$> compIf ws))

starExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (StarExpr ws SrcInfo)
starExpr ws =
  annotated $
  StarExpr <$>
  (char '*' *> beforeF (many ws) (expr ws))

exprList
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (ExprList ws SrcInfo)
exprList ws =
  annotated $
  ExprList <$>
  exprOrStar <*>
  manyF
    (beforeF
      (try $ between' (many ws) comma <* notFollowedBy (void kIn <|> void newlineChar))
      exprOrStar) <*>
  optional (try $ before (many ws) comma)
  where
    exprOrStar = (InL <$> expr ws) <|> (InR <$> starExpr ws)

compFor
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (CompFor ws SrcInfo)
compFor ws =
  annotated $
  CompFor <$>
  beforeF
    (try . between'1 ws $ kFor)
    ((after1F <*> exprList) ws) <*>
  (kIn *> (before1F <*> orTest) ws) <*>
  optionalF (compIter ws)

stringPrefix :: (DeltaParsing m, LookAheadParsing m) => m StringPrefix
stringPrefix =
  (char 'r' $> StringPrefix_r) <|>
  (char 'u' $> StringPrefix_u) <|>
  (char 'R' $> StringPrefix_R) <|>
  (char 'u' $> StringPrefix_U)

shortString :: (HasCallStack, DeltaParsing m, LookAheadParsing m) => Unspaced m (ShortString SrcInfo)
shortString = shortStringSingle <|> shortStringDouble
  where
    shortStringSingle =
      annotated $
      ShortStringSingle <$>
      (singleQuote *>
       parseStringContentSingle parseShortStringCharSingle singleQuote <*
       singleQuote)

    shortStringDouble =
      annotated $
      ShortStringDouble <$>
      (doubleQuote *>
       parseStringContentDouble parseShortStringCharDouble doubleQuote <*
       doubleQuote)

longString :: (HasCallStack, DeltaParsing m, LookAheadParsing m) => Unspaced m (LongString SrcInfo)
longString = longStringDouble <|> longStringSingle
  where
    longStringSingle =
      annotated $
      LongStringSingle <$>
      (tripleSinglequote *>
       parseStringContentSingle parseLongStringChar tripleSinglequote <*
       tripleSinglequote)

    longStringDouble =
      annotated $
      LongStringDouble <$>
      (tripleDoublequote *>
       parseStringContentDouble parseLongStringChar tripleDoublequote <*
       tripleDoublequote)

stringLiteral :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (StringLiteral SrcInfo)
stringLiteral =
  annotated $
  StringLiteral <$>
  beforeF
    (optional stringPrefix)
    ((InR <$> longString) <|> (InL <$> shortString))

bytesPrefix :: (DeltaParsing m, LookAheadParsing m) => m BytesPrefix
bytesPrefix =
  (char 'b' *>
    ((char 'r' $> BytesPrefix_br) <|>
     (char 'R' $> BytesPrefix_bR) <|>
     pure BytesPrefix_b)) <|>
  (char 'B' *>
    ((char 'r' $> BytesPrefix_Br) <|>
     (char 'R' $> BytesPrefix_BR) <|>
     pure BytesPrefix_B)) <|>
  (char 'r' *>
    ((char 'b' $> BytesPrefix_rb) <|>
     (char 'B' $> BytesPrefix_rB))) <|>
  (char 'R' *>
    ((char 'b' $> BytesPrefix_Rb) <|>
     (char 'B' $> BytesPrefix_RB)))

shortBytes :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (ShortBytes SrcInfo)
shortBytes = shortBytesSingle <|> shortBytesDouble
  where
    shortBytesSingle =
      annotated $
      ShortBytesSingle <$>
      (singleQuote *>
       parseStringContentSingle parseShortBytesCharSingle singleQuote <*
       singleQuote)

    shortBytesDouble =
      annotated $
      ShortBytesDouble <$>
      (doubleQuote *>
       parseStringContentDouble parseShortBytesCharDouble doubleQuote <*
       doubleQuote)

longBytes :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (LongBytes SrcInfo)
longBytes =
  (try longBytesSingle <|> longBytesSingleEmpty) <|>
  (try longBytesDouble <|> longBytesDoubleEmpty)
  where
    longBytesSingleEmpty =
      annotated $
      tripleSinglequote *>
      tripleSinglequote $>
      LongBytesSingleEmpty

    longBytesDoubleEmpty =
      annotated $
      tripleDoublequote *>
      tripleDoublequote $>
      LongBytesDoubleEmpty

    longBytesSingle =
      annotated $
      LongBytesSingle <$>
      (tripleSinglequote *>
       parseStringContentSingle parseLongBytesChar tripleSinglequote <*
       tripleSinglequote)

    longBytesDouble =
      annotated $
      LongBytesDouble <$>
      (tripleDoublequote *>
       parseStringContentDouble parseLongBytesChar tripleDoublequote <*
       tripleDoublequote)

bytesLiteral :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (BytesLiteral SrcInfo)
bytesLiteral =
  annotated $
  BytesLiteral <$>
  bytesPrefix <*>
  ((InR <$> longBytes) <|> (InL <$> shortBytes))

nonZeroDigit :: (DeltaParsing m, LookAheadParsing m) => m NonZeroDigit
nonZeroDigit =
  (char '1' $> NonZeroDigit_1) <|>
  (char '2' $> NonZeroDigit_2) <|>
  (char '3' $> NonZeroDigit_3) <|>
  (char '4' $> NonZeroDigit_4) <|>
  (char '5' $> NonZeroDigit_5) <|>
  (char '6' $> NonZeroDigit_6) <|>
  (char '7' $> NonZeroDigit_7) <|>
  (char '8' $> NonZeroDigit_8) <|>
  (char '9' $> NonZeroDigit_9)

digit' :: (DeltaParsing m, LookAheadParsing m) => m Digit
digit' =
  (char '0' $> Digit_0) <|>
  (char '1' $> Digit_1) <|>
  (char '2' $> Digit_2) <|>
  (char '3' $> Digit_3) <|>
  (char '4' $> Digit_4) <|>
  (char '5' $> Digit_5) <|>
  (char '6' $> Digit_6) <|>
  (char '7' $> Digit_7) <|>
  (char '8' $> Digit_8) <|>
  (char '9' $> Digit_9)

octDigit :: (DeltaParsing m, LookAheadParsing m) => m OctDigit
octDigit =
  (char '0' $> OctDigit_0) <|>
  (char '1' $> OctDigit_1) <|>
  (char '2' $> OctDigit_2) <|>
  (char '3' $> OctDigit_3) <|>
  (char '4' $> OctDigit_4) <|>
  (char '5' $> OctDigit_5) <|>
  (char '6' $> OctDigit_6) <|>
  (char '7' $> OctDigit_7)

hexDigit :: (DeltaParsing m, LookAheadParsing m) => m HexDigit
hexDigit =
  (char '0' $> HexDigit_0) <|>
  (char '1' $> HexDigit_1) <|>
  (char '2' $> HexDigit_2) <|>
  (char '3' $> HexDigit_3) <|>
  (char '4' $> HexDigit_4) <|>
  (char '5' $> HexDigit_5) <|>
  (char '6' $> HexDigit_6) <|>
  (char '7' $> HexDigit_7) <|>
  (char '8' $> HexDigit_8) <|>
  (char '9' $> HexDigit_9) <|>
  (char 'a' $> HexDigit_a) <|>
  (char 'A' $> HexDigit_A) <|>
  (char 'b' $> HexDigit_b) <|>
  (char 'B' $> HexDigit_B) <|>
  (char 'c' $> HexDigit_c) <|>
  (char 'C' $> HexDigit_C) <|>
  (char 'd' $> HexDigit_d) <|>
  (char 'D' $> HexDigit_D) <|>
  (char 'e' $> HexDigit_e) <|>
  (char 'E' $> HexDigit_E) <|>
  (char 'f' $> HexDigit_f) <|>
  (char 'F' $> HexDigit_F)

binDigit :: (DeltaParsing m, LookAheadParsing m) => m BinDigit
binDigit = (char '0' $> BinDigit_0) <|> (char '1' $> BinDigit_1)

integer :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (Integer' SrcInfo)
integer =
  integerBin <|>
  integerOct <|>
  integerHex <|>
  integerDecimal
  where
    integerDecimal =
      annotated $
      IntegerDecimal <$>
      ((Left <$> liftA2 (,) nonZeroDigit (many digit')) <|>
      (Right <$> some1 zero))
    integerOct =
      annotated .
      fmap IntegerOct $
      Before <$> (try $ zero *> oO) <*> some1 octDigit
    integerHex =
      annotated .
      fmap IntegerHex $
      Before <$> (try $ zero *> xX) <*> some1 hexDigit
    integerBin =
      annotated .
      fmap IntegerBin $
      Before <$> (try $ zero *> bB) <*> some1 binDigit

plusOrMinus :: (DeltaParsing m, LookAheadParsing m) => m (Either Plus Minus)
plusOrMinus = (Left <$> plus) <|> (Right <$> minus)

float :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (Float' SrcInfo)
float = try floatDecimalBase <|> try floatDecimalNoBase <|> floatNoDecimal
  where
    floatDecimalBase =
      annotated $
      FloatDecimalBase <$>
      try (some1 digit') <*>
      (char '.' *> optionalF (some1 digit')) <*>
      ex

    floatDecimalNoBase =
      annotated $
      FloatDecimalNoBase <$>
      (char '.' *> some1 digit') <*>
      ex

    floatNoDecimal =
      annotated $
      FloatNoDecimal <$>
      try (some1 digit') <*>
      (Before <$> eE <*> some1 digit')

    ex = optional (try $ Before <$> eE <*> some1 digit')

imag :: (DeltaParsing m, LookAheadParsing m) => Unspaced m (Imag SrcInfo)
imag =
  annotated . fmap Imag $
  Compose <$>
  (flip After <$> floatOrInt <*> jJ)
  where
    floatOrInt = fmap InL float <|> fmap (InR . Const) (some1 digit')

dictItem
  :: ( DeltaParsing m
     , LookAheadParsing m
     )
  => Unspaced m ws
  -> Unspaced m (DictItem ws SrcInfo)
dictItem ws =
  annotated $
  DictItem <$>
  test ws <*>
  between' (many ws) colon <*>
  test ws

dictUnpacking
  :: ( DeltaParsing m
     , LookAheadParsing m
     )
  => Unspaced m ws
  -> Unspaced m (DictUnpacking ws SrcInfo)
dictUnpacking ws =
  annotated $
  DictUnpacking <$>
  beforeF (between' (many ws) doubleAsterisk) (expr ws)

dictOrSetMaker
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (DictOrSetMaker ws SrcInfo)
dictOrSetMaker ws = dictOrSetMakerDict <|> dictOrSetMakerSet
  where
    dictOrSetMakerDict =
      annotated $
      DictOrSetMakerDict <$>
      itemOrUnpacking <*>
      dictCompOrList

    itemOrUnpacking = try (InL <$> dictItem ws) <|> (InR <$> dictUnpacking ws)

    dictCompOrList =
      (InL <$> compFor ws) <|>
      (InR <$> afterF
        (optional . try $ between' (many ws) comma)
        (manyF $
         beforeF
           (try $ between' (many ws) comma <* notFollowedBy (char '}'))
           itemOrUnpacking))

    dictOrSetMakerSet =
      annotated $
      DictOrSetMakerSet <$>
      testOrStar <*>
      setCompOrList

    testOrStar = (InL <$> test ws) <|> (InR <$> starExpr ws)

    setCompOrList =
      (InL <$> compFor ws) <|>
      (InR <$> afterF
        (optional . try $ between' (many ws) comma)
        (manyF $
         beforeF (try $ between' (many ws) comma <* notFollowedBy (char '}')) testOrStar))


tupleTestlistComp
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (TupleTestlistComp ws SrcInfo)
tupleTestlistComp ws = do
  t <- testOrStar
  tupleTestlistCompFor t <|> tupleTestlistCompList t
  where
    tupleTestlistCompFor t =
      annotated $
      TupleTestlistCompFor t <$>
      compFor ws

    tupleTestlistCompList t =
      annotated $
      TupleTestlistCompList t <$>
      manyF
        (beforeF
          (try $ between' (many ws) comma <* notFollowedBy (char ')'))
          testOrStar) <*>
      optional (try $ before (many ws) comma)

    testOrStar = (InL <$> test ws) <|> (InR <$> starExpr ws)

listTestlistComp
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (ListTestlistComp ws SrcInfo)
listTestlistComp ws = do
  t <- testOrStar
  listTestlistCompFor t <|> listTestlistCompList t
  where
    listTestlistCompFor t =
      annotated $
      ListTestlistCompFor t <$>
      compFor ws

    listTestlistCompList t =
      annotated $
      ListTestlistCompList t <$>
      manyF
        (beforeF
          (try $ between' (many ws) comma <* notFollowedBy (char ']'))
          testOrStar) <*>
      optional (try $ before (many ws) comma)

    testOrStar = (InL <$> test ws) <|> (InR <$> starExpr ws)

testList
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (TestList ws SrcInfo)
testList ws =
  annotated $
  TestList <$>
  test ws <*>
  manyF
    (beforeF
      (try $ between' (many ws) comma <* notFollowedBy (void semicolon <|> void newlineChar))
      (test ws)) <*>
  optional (try $ before (many ws) comma)

yieldArg
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (YieldArg ws SrcInfo)
yieldArg ws = yieldArgFrom <|> yieldArgList
  where
    yieldArgFrom =
      annotated $
      YieldArgFrom <$>
      (kFrom *> (before1F <*> test) ws)
    yieldArgList =
      annotated $
      YieldArgList <$> testList ws

yieldExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (YieldExpr ws SrcInfo)
yieldExpr ws =
  annotated $
  YieldExpr <$>
  (string "yield" *> optionalF (try $ (before1F <*> yieldArg) ws))

atomNoInt
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (AtomNoInt ws SrcInfo)
atomNoInt ws =
  atomParen <|>
  atomBracket <|>
  atomCurly <|>
  try atomFloat <|>
  (try atomString <?> "string literal") <|>
  atomEllipsis <|>
  (try atomNone <?> "None") <|>
  (try atomTrue <?> "True") <|>
  (try atomFalse <?> "False") <|>
  atomIdentifier
  where
    atomIdentifier =
      annotated $
      AtomIdentifier <$>
      identifier

    atomParen =
      annotated $
      AtomParen <$>
      (char '(' *>
       between'F
         (many anyWhitespaceChar)
         (optionalF
           ((InL <$> yieldExpr anyWhitespaceChar) <|>
            (InR <$> tupleTestlistComp anyWhitespaceChar))) <*
       char ')')

    atomBracket =
      annotated $
      AtomBracket <$>
        (char '[' *>
         between'F (many anyWhitespaceChar)
           (optionalF $ listTestlistComp anyWhitespaceChar) <*
         char ']')

    atomCurly =
      annotated $
      AtomCurly <$>
        (char '{' *>
         between'F (many anyWhitespaceChar)
           (optionalF $ dictOrSetMaker anyWhitespaceChar) <*
         char '}')

    atomFloat =
      annotated $
      AtomFloat <$> float

    stringOrBytes = (InL <$> try stringLiteral) <|> (InR <$> bytesLiteral)

    atomString =
      annotated $
      AtomString <$>
      stringOrBytes <*>
      manyF (try $ beforeF (many ws) stringOrBytes)

    atomEllipsis =
      annotated $
      string "..." $> AtomEllipsis

    atomNone =
      annotated $
      (string "None" *> notFollowedBy idContinue) $> AtomNone

    atomTrue =
      annotated $
      (string "True" *> notFollowedBy idContinue) $> AtomTrue

    atomFalse =
      annotated $
      (string "False" *> notFollowedBy idContinue) $> AtomFalse

atom
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Atom ws SrcInfo)
atom ws =
  atomInteger <|>
  annotated (AtomNoInt <$> atomNoInt ws)
  where
    atomInteger =
      annotated $
      AtomInteger <$> integer

sliceOp
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (SliceOp ws SrcInfo)
sliceOp ws =
  annotated $
  SliceOp <$>
  (char ':' *> optionalF (try $ beforeF (many ws) (test ws)))

subscript
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Subscript ws SrcInfo)
subscript ws = try subscriptTest <|> subscriptSlice
  where
    subscriptTest =
      annotated $
      SubscriptTest <$>
      test ws <* notFollowedBy (try $ many ws *> char ':')
    subscriptSlice =
      annotated $
      SubscriptSlice <$>
      afterF (many ws) (optionalF $ test ws) <*>
      after (many ws) (char ':' $> Colon) <*>
      optionalF (try $ afterF (many ws) (test ws)) <*>
      optionalF (try $ afterF (many ws) (sliceOp ws))

subscriptList
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (SubscriptList ws SrcInfo)
subscriptList ws =
  annotated $
  SubscriptList <$>
  subscript ws <*>
  manyF
    (beforeF
      (try $ between' (many ws) comma <* notFollowedBy (char ']'))
      (subscript ws)) <*>
  optional (try $ before (many ws) comma)

trailer
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Trailer ws SrcInfo)
trailer ws = trailerCall <|> trailerSubscript <|> trailerAccess
  where
    trailerCall =
      annotated $
      TrailerCall <$>
        (char '(' *>
         anyWhitespaceBeforeF
           (optionalF $
            argumentList
              (liftA2
                 Pair
                 (test anyWhitespaceChar)
                 (optionalF (compFor anyWhitespaceChar)))
              (test anyWhitespaceChar)
              identifier
              test) <*
         char ')')

    trailerSubscript =
      annotated $
      TrailerSubscript <$>
      (char '[' *>
       between'F (many anyWhitespaceChar) (subscriptList anyWhitespaceChar) <*
       char ']')

    trailerAccess =
      annotated $
      TrailerAccess <$>
      (char '.' *> beforeF (many ws) identifier)

atomExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (AtomExpr ws SrcInfo)
atomExpr ws =
  annotated $ do
    aw <- optional $ string "await" *> after1 ws (pure KAwait)
    (do
        a@(AtomNoInt anoi _) <- annotated $ AtomNoInt <$> atomNoInt ws
        (AtomExprTrailers aw anoi <$>
         some1F
           (beforeF
             (try $ many ws <* lookAhead (char '.' <|> char '[' <|> char '('))
             (trailer ws))) <|>
          pure (AtomExprSingle aw a)) <|>
      (AtomExprSingle aw <$> annotated (AtomInteger <$> integer))

power
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Power ws SrcInfo)
power ws =
  annotated $
  Power <$>
  atomExpr ws <*>
  optionalF (beforeF (try $ between' (many ws) doubleAsterisk) (factor ws))

factorOp :: (DeltaParsing m, LookAheadParsing m) => m FactorOperator
factorOp =
  (char '-' $> FactorNeg) <|>
  (char '+' $> FactorPos) <|>
  (char '~' $> FactorInv)

factor
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Factor ws SrcInfo)
factor ws = factorOne <|> factorNone
  where
    factorNone = annotated $ FactorNone <$> power ws
    factorOne =
      annotated $
      FactorOne <$>
      after (many ws) factorOp <*>
      factor ws

termOp :: (DeltaParsing m, LookAheadParsing m) => m TermOperator
termOp =
  (char '*' $> TermMult) <|>
  (char '@' $> TermAt) <|>
  (char '/' *> ((char '/' $> TermFloorDiv) <|> pure TermDiv)) <|>
  (char '%' $> TermMod)

term
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Term ws SrcInfo)
term ws =
  annotated $
  Term <$>
  factor ws <*>
  manyF (beforeF (try $ between' (many ws) termOp) (factor ws))

arithExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (ArithExpr ws SrcInfo)
arithExpr ws =
  annotated $
  ArithExpr <$>
  term ws <*>
  manyF (beforeF (try $ between' (many ws) plusOrMinus) (term ws))

shiftExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (ShiftExpr ws SrcInfo)
shiftExpr ws =
  annotated $
  ShiftExpr <$>
  arithExpr ws <*>
  manyF (beforeF (try $ between' (many ws) shiftLeftOrRight) (arithExpr ws))
  where
    shiftLeftOrRight =
      (symbol "<<" $> Left DoubleLT) <|>
      (symbol ">>" $> Right DoubleGT)

andExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (AndExpr ws SrcInfo)
andExpr ws =
  annotated $
  AndExpr <$>
  shiftExpr ws <*>
  manyF (beforeF (try . between' (many ws) $ char '&' $> Ampersand) (shiftExpr ws))

xorExpr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (XorExpr ws SrcInfo)
xorExpr ws =
  annotated $
  XorExpr <$>
  andExpr ws <*>
  manyF (beforeF (try . between' (many ws) $ char '^' $> S.Caret) (andExpr ws))

expr
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Expr ws SrcInfo)
expr ws =
  annotated $
  Expr <$>
  xorExpr ws <*>
  manyF (beforeF (try . between' (many ws) $ char '|' $> Pipe) (xorExpr ws))

compOperator :: (DeltaParsing m, LookAheadParsing m) => m ws -> m (CompOperator ws)
compOperator ws =
  try compEq <|>
  try compGEq <|>
  try compLEq <|>
  try compNEq <|>
  try compLT <|>
  try compGT <|>
  try compIsNot <|>
  try compIs <|>
  try compIn <|>
  compNotIn
  where
    compEq =
      CompEq <$>
      (many ws <* string "==") <*>
      many ws

    compGEq =
      CompGEq <$>
      (many ws <* string ">=") <*>
      many ws

    compNEq =
      CompNEq <$>
      (many ws <* string "!=") <*>
      many ws

    compLEq =
      CompLEq <$>
      (many ws <* string "<=") <*>
      many ws

    compLT =
      CompLT <$>
      (many ws <* string "<") <*>
      many ws

    compGT =
      CompGT <$>
      (many ws <* string ">") <*>
      many ws

    compIsNot =
      CompIsNot <$>
      (some1 ws <* string "is") <*>
      (some1 ws <* string "not") <*>
      some1 ws

    compIs =
      CompIs <$>
      (some1 ws <* string "is") <*>
      some1 ws

    compIn =
      CompIn <$>
      (some1 ws <* string "in") <*>
      some1 ws

    compNotIn =
      CompNotIn <$>
      (some1 ws <* string "not") <*>
      (some1 ws <* string "in") <*>
      some1 ws

comparison
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (Comparison ws SrcInfo)
comparison ws =
  annotated $
  Comparison <$>
  expr ws <*>
  manyF (beforeF (try $ compOperator ws) (expr ws))

notTest
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (NotTest ws SrcInfo)
notTest ws = notTestMany <|> notTestOne
  where
    notTestMany =
      annotated $
      NotTestMany <$>
      beforeF (after1 ws $ string "not" $> KNot) (notTest ws)

    notTestOne =
      annotated $ NotTestOne <$> comparison ws

andTest
  :: (DeltaParsing m, LookAheadParsing m)
  => Unspaced m ws
  -> Unspaced m (AndTest ws SrcInfo)
andTest ws =
  annotated $
  AndTest <$>
  notTest ws <*>
  manyF (beforeF (try $ between'1 ws kAnd) (notTest ws))