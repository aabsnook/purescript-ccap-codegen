module Ccap.Codegen.PureScript
  ( outputSpec
  ) where

import Prelude
import Ccap.Codegen.Annotations as Annotations
import Ccap.Codegen.Ast as Ast
import Ccap.Codegen.Cst as Cst
import Ccap.Codegen.Parser.Export as Export
import Ccap.Codegen.Shared (DelimitedLiteralDir(..), OutputSpec, delimitedLiteral, fastPathDecoderType, indented)
import Control.Monad.Writer (class MonadTell, Writer, runWriter, tell)
import Data.Array ((:))
import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NonEmptyArray
import Data.Compactable (compact)
import Data.Foldable (fold, intercalate)
import Data.Function (on)
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.String (Pattern(..))
import Data.String as String
import Data.Traversable (for, traverse)
import Data.TraversableWithIndex (forWithIndex)
import Data.Tuple (Tuple(..), fst)
import Node.Path (FilePath)
import Text.PrettyPrint.Boxes (Box, char, emptyBox, hsep, punctuateH, render, text, vcat, vsep, (//), (<<+>>), (<<>>))
import Text.PrettyPrint.Boxes as Boxes

type PsImport
  = { mod :: String
    , typ :: Maybe String
    , alias :: Maybe String
    }

type Codegen
  = Writer (Array PsImport)

runCodegen :: forall a. Codegen a -> Tuple a (Array PsImport)
runCodegen c = runWriter c

emit :: forall m a. MonadTell (Array PsImport) m => PsImport -> a -> m a
emit imp a = map (const a) (tell [ imp ])

oneModule :: Ast.Module -> Box
oneModule (Ast.Module mod) =
  vsep 1 Boxes.left
    let
      Tuple body imports = runCodegen (traverse typeDecl mod.types)

      allImports = imports <> (mod.imports <#> importModule)
    in
      text "-- This file is automatically generated. Do not edit."
        : text ("module " <> mod.exports.pursPkg <> " where")
        : vcat Boxes.left
            ((renderImports <<< mergeImports $ allImports) <#> append "import " >>> text)
        : NonEmptyArray.toArray body

renderImports :: Array PsImport -> Array String
renderImports =
  map \{ mod, typ, alias } ->
    mod
      <> (fromMaybe "" (typ <#> (\t -> " (" <> t <> ")")))
      <> (fromMaybe "" (alias <#> (" as " <> _)))

mergeImports :: Array PsImport -> Array PsImport
mergeImports imps =
  let
    sorted = Array.sortBy ((compare `on` _.mod) <> (compare `on` _.alias)) imps

    grouped = Array.groupBy (\a b -> a.mod == b.mod && a.alias == b.alias) sorted
  in
    grouped
      <#> \group ->
          (NonEmptyArray.head group)
            { typ =
              traverse _.typ group <#> NonEmptyArray.toArray
                >>> Array.sort
                >>> Array.nub
                >>> intercalate ", "
            }

outputSpec :: OutputSpec
outputSpec =
  { render: Just <<< render <<< oneModule
  , filePath: modulePath
  }

modulePath :: Ast.Module -> FilePath
modulePath (Ast.Module mod) = Export.toPath mod.exports.pursPkg <> ".purs"

primitive :: Cst.Primitive -> Codegen Box
primitive = case _ of
  Cst.PBoolean -> pure (text "Boolean")
  Cst.PInt -> pure (text "Int")
  Cst.PDecimal -> emit { mod: "Data.Decimal", typ: Just "Decimal", alias: Nothing } (text "Decimal")
  Cst.PSmallInt -> pure (text "Int")
  Cst.PString -> pure (text "String")
  Cst.PStringValidationHack -> pure (text "String")
  Cst.PJson -> emit { mod: "Data.Argonaut.Core", typ: Nothing, alias: Just "A" } (text "A.Json")

type Extern
  = { prefix :: String, t :: String }

externalType :: Extern -> Codegen Box
externalType { prefix, t } = emit { mod: prefix, typ: Just t, alias: Just prefix } $ text (prefix <> "." <> t)

moduleName :: Ast.Module -> String
moduleName (Ast.Module { exports: { pursPkg } }) = fromMaybe pursPkg $ Array.last $ Export.split pursPkg

importModule :: Ast.Module -> PsImport
importModule mod@(Ast.Module m) =
  { mod: m.exports.pursPkg
  , typ: Nothing
  , alias: Just $ moduleName mod
  }

splitType :: String -> Maybe Extern
splitType s = do
  i <- String.lastIndexOf (Pattern ".") s
  let
    prefix = String.take i s
  let
    t = String.drop (i + 1) s
  pure $ { prefix, t }

typeDecl :: Ast.TypeDecl -> Codegen Box
typeDecl (Ast.TypeDecl { name, topType: tt, annots, params: typeParams }) =
  let
    pp =
      if Array.null typeParams then
        ""
      else
        " " <> intercalate " " (map (\(Cst.TypeParam p) -> p) typeParams)

    dec kw = text kw <<+>> text (name <> pp) <<+>> char '='
  in
    case tt of
      Ast.Typ t -> do
        ty <- tyType t false
        j <- jsonCodec t false
        pure $ (dec "type" <<+>> ty)
          // defJsonCodec name typeParams j
      Ast.Wrap t -> case Annotations.getWrapOpts "purs" annots of
        Nothing -> do
          other <- otherInstances name typeParams
          ty <- tyType t false
          j <- newtypeJsonCodec t
          newtype_ <- newtypeInstances name
          pure
            $ dec "newtype"
            <<+>> text name
            <<+>> ty
            // newtype_
            // other
            // defJsonCodec name typeParams j
        Just { typ, decode, encode } -> do
          ty <- externalRef typ
          j <- externalJsonCodec t decode encode
          pure
            $ dec "type"
            <<+>> ty
            // defJsonCodec name typeParams j
      Ast.Record props -> do
        recordDecl <- record props <#> \p -> dec "type" // indented p
        recordDecoderApiTypeDecl <- recordDecoderApi props <#> \p -> text ("type DecoderApi_" <> name <> pp <> " =") // indented p
        recordDecoderApiTypeDeclDecl <- recordDecoderApiDecl props <#> \p -> text ("decoderApi_" <> name <> defParams typeParams <> " =") // indented p
        codec <- recordJsonCodec name typeParams props
        pure
          $ recordDecl
          // recordDecoderApiTypeDecl
          // text ("decoderApi_" <> name <> " ::" <> declParamTypes typeParams <> "DecoderApi_" <> name <> pp)
          // recordDecoderApiTypeDeclDecl
          // text
              ( "foreign import decode_"
                  <> name
                  <> " ::"
                  <> declForAll typeParams
                  <> " DecoderApi_"
                  <> name
                  <> pp
                  <> " -> A.Json -> E.Either JsonDecodeError "
                  <> if Array.null typeParams then
                      name
                    else
                      "(" <> name <> pp <> ")"
              )
          // defJsonCodec name typeParams codec
      Ast.Sum constructors ->
        maybe
          ( do
              other <- otherInstances name typeParams
              cs <-
                for constructors case _ of
                  Ast.NoArg (Cst.ConstructorName n) -> pure (text n)
                  Ast.WithArgs (Cst.ConstructorName n) args -> do
                    params <- tyTypeOrParams (NonEmptyArray.toArray args)
                    pure (text n <<+>> hsep 1 Boxes.top params)
              codec <- sumJsonCodec constructors
              pure
                $ dec "data"
                // indented (hsep 1 Boxes.bottom $ vcat Boxes.left <$> [ NonEmptyArray.drop 1 cs <#> \_ -> char '|', NonEmptyArray.toArray cs ])
                // other
                // defJsonCodec name typeParams codec
          )
          ( \vs -> do
              other <- otherInstances name typeParams
              codec <- noArgSumJsonCodec name vs
              pure
                $ dec "data"
                // indented (hsep 1 Boxes.bottom $ vcat Boxes.left <$> [ NonEmptyArray.drop 1 vs <#> \_ -> char '|', NonEmptyArray.toArray (vs <#> text) ])
                // other
                // defJsonCodec name typeParams codec
          )
          (Ast.noArgConstructorNames constructors)

noArgSumJsonCodec :: String -> NonEmptyArray String -> Codegen Box
noArgSumJsonCodec name vs = do
  tell
    [ { mod: "Data.Either", typ: Just "Either(..)", alias: Nothing }
    , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError(..)", alias: Just "JDE" }
    ]
  let
    encode =
      text "encode: case _ of"
        // indented (branches encodeBranch)

    decode =
      text "decode: case _ of"
        // indented (branches decodeBranch // fallthrough)
  emitRuntime $ text "R.composeCodec"
    // indented (delimitedLiteral Vert '{' '}' [ decode, encode ] // text "R.jsonCodec_string")
  where
  branches branch = vcat Boxes.left (vs <#> branch)

  encodeBranch v = text v <<+>> text "->" <<+>> text (show v)

  decodeBranch v = text (show v) <<+>> text "-> Right" <<+>> text v

  fallthrough = text $ "s -> Left $ JDE.TypeMismatch $ \"Invalid value \" <> show s <> \" for " <> name <> "\""

sumJsonCodec :: NonEmptyArray Ast.Constructor -> Codegen Box
sumJsonCodec cs = do
  tell
    [ { mod: "Data.Either", typ: Nothing, alias: Just "E" }
    , { mod: "Data.Tuple", typ: Nothing, alias: Just "T" }
    , { mod: "Data.Array", typ: Nothing, alias: Just "Array" }
    , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError", alias: Nothing }
    , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError(..)", alias: Just "JDE" }
    ]
  encodeBranches <- traverse encodeBranch cs
  decodeBranches <- traverse decodeBranch cs
  let
    encode =
      text "encode: case _ of"
        // indented (vcat Boxes.left encodeBranches)

    decode =
      text "decode: case _ of"
        // indented (vcat Boxes.left (decodeBranches `NonEmptyArray.snoc` fallThrough))
  emitRuntime $ text "R.composeCodec"
    // indented (delimitedLiteral Vert '{' '}' [ decode, encode ] // text "R.jsonCodec_constructor")
  where
  encodeBranch :: Ast.Constructor -> Codegen Box
  encodeBranch = case _ of
    Ast.NoArg (Cst.ConstructorName n) -> pure (text n <<+>> text ("-> T.Tuple " <> show n <> " []"))
    Ast.WithArgs (Cst.ConstructorName n) params -> do
      encodeParams <-
        forWithIndex params \i typ -> do
          x <- case typ of
            Ast.TType t -> jsonCodec t true
            Ast.TParam (Cst.TypeParam p) -> pure (text ("jsonCodec_param_" <> p))
          pure (x <<>> text (".encode param_" <> show i))
      pure
        ( text
            ( n
                <> " "
                <> intercalate " " (map (\i -> "param_" <> show i) (Array.range 0 (NonEmptyArray.length params - 1)))
                <> " -> T.Tuple "
                <> show n
                <> " ["
            )
            <<>> punctuateH Boxes.top (text ", ") encodeParams
            <<>> text "]"
        )

  decodeBranch :: Ast.Constructor -> Codegen Box
  decodeBranch = case _ of
    Ast.NoArg (Cst.ConstructorName n) -> pure (text ("T.Tuple " <> show n <> " [] -> E.Right " <> n))
    Ast.WithArgs (Cst.ConstructorName n) params -> do
      decodeParams <-
        forWithIndex params \i typ -> do
          x <- case typ of
            Ast.TType t -> jsonCodec t true
            Ast.TParam (Cst.TypeParam p) -> pure (text ("jsonCodec_param_" <> p))
          pure (text ("param_" <> show i <> " <- ") <<>> x <<>> text (".decode jsonParam_" <> show i))
      pure
        ( text
            ( "T.Tuple "
                <> show n
                <> " ["
                <> intercalate ", " (map (\i -> "jsonParam_" <> show i) (Array.range 0 (NonEmptyArray.length params - 1)))
                <> "] -> do"
            )
            // indented
                ( vcat Boxes.left
                    ( NonEmptyArray.toArray decodeParams
                        <> [ text
                              ( "E.Right ("
                                  <> n
                                  <> " "
                                  <> intercalate " " (map (\i -> "param_" <> show i) (Array.range 0 (NonEmptyArray.length params - 1)))
                                  <> ")"
                              )
                          ]
                    )
                )
        )

  fallThrough = text $ "T.Tuple cn params -> E.Left $ JDE.TypeMismatch $ \"Pattern match failed for \" <> show cn <> \" with \" <> show (Array.length params) <> \" parameters\""

needsParens :: Ast.Typ -> Boolean
needsParens = case _ of
  Ast.Primitive _ -> false
  Ast.Ref { params } -> not Array.null params
  Ast.Array _ -> true
  Ast.Option _ -> true

newtypeInstances :: String -> Codegen Box
newtypeInstances name = do
  tell
    [ { mod: "Data.Newtype", typ: Just "class Newtype", alias: Nothing }
    , { mod: "Data.Argonaut.Decode", typ: Just "class DecodeJson", alias: Nothing }
    , { mod: "Data.Argonaut.Encode", typ: Just "class EncodeJson", alias: Nothing }
    ]
  pure
    $ text ("derive instance newtype" <> name <> " :: Newtype " <> name <> " _")
    // text ("instance encodeJson" <> name <> " :: EncodeJson " <> name <> " where ")
    // indented (text $ "encodeJson a = jsonCodec_" <> name <> ".encode a")
    // text ("instance decodeJson" <> name <> " :: DecodeJson " <> name <> " where ")
    // indented (text $ "decodeJson a = jsonCodec_" <> name <> ".decode a")

otherInstances :: String -> Array Cst.TypeParam -> Codegen Box
otherInstances name params = do
  tell
    [ { mod: "Prelude", typ: Nothing, alias: Nothing }
    , { mod: "Data.Generic.Rep", typ: Just "class Generic", alias: Nothing }
    , { mod: "Data.Show.Generic", typ: Just "genericShow", alias: Nothing }
    ]
  let
    nameWithParams =
      if Array.null params then
        name
      else
        "(" <> name <> " " <> intercalate " " (map (\(Cst.TypeParam p) -> p) params) <> ")"

    depends :: String -> String
    depends which = case params of
      [] -> ""
      [ Cst.TypeParam p ] -> which <> " " <> p <> " => "
      _ -> "(" <> intercalate ", " (map (\(Cst.TypeParam p) -> which <> " " <> p) params) <> ") => "
  pure
    $ text ("derive instance eq" <> name <> " :: " <> depends "Eq" <> "Eq " <> nameWithParams)
    // text ("derive instance ord" <> name <> " :: " <> depends "Ord" <> "Ord " <> nameWithParams)
    // text ("derive instance generic" <> name <> " :: Generic " <> nameWithParams <> " _")
    // text ("instance show" <> name <> " :: " <> depends "Show" <> "Show " <> nameWithParams <> " where")
    // indented (text "show a = genericShow a")

tyType :: Ast.Typ -> Boolean -> Codegen Box
tyType tt includeParensIfNeeded =
  let
    wrap tycon t = tyType t true <#> \ty -> text tycon <<+>> ty
  in
    do
      result <- case tt of
        Ast.Primitive p -> primitive p
        Ast.Ref { decl, typ, params } -> internalTypeRef decl params typ
        Ast.Array (Ast.TType t) -> wrap "Array" t
        Ast.Array (Ast.TParam (Cst.TypeParam t)) -> pure (text ("Array " <> t))
        Ast.Option (Ast.TType t) -> tell (pure { mod: "Data.Maybe", typ: Just "Maybe", alias: Nothing }) >>= const (wrap "Maybe" t)
        Ast.Option (Ast.TParam (Cst.TypeParam t)) -> pure (text ("Maybe " <> t))
      pure
        ( if includeParensIfNeeded && needsParens tt then
            parens result
          else
            result
        )

tyTypeOrParams :: Array Ast.TypeOrParam -> Codegen (Array Box)
tyTypeOrParams typeOrParams =
  for typeOrParams case _ of
    Ast.TType ttt -> tyType ttt true
    Ast.TParam (Cst.TypeParam c) -> pure (text c)

internalRef :: Maybe (Tuple Ast.Module Ast.TypeDecl) -> String -> Array Box -> Box
internalRef decl typ paramsBoxes = do
  let
    path = map (moduleName <<< fst) decl

    paramsBox =
      if Array.null paramsBoxes then
        emptyBox 0 0
      else
        text " " <<>> hsep 1 Boxes.top paramsBoxes
  text (qualify path typ) <<>> paramsBox

internalTypeRef :: Maybe (Tuple Ast.Module Ast.TypeDecl) -> Array Ast.TypeOrParam -> String -> Codegen Box
internalTypeRef decl params typ = do
  pp <- tyTypeOrParams params
  pure (internalRef decl typ pp)

internalCodecRef :: Maybe (Tuple Ast.Module Ast.TypeDecl) -> Array Ast.TypeOrParam -> String -> Codegen Box
internalCodecRef decl params typ = do
  pp <-
    for params case _ of
      Ast.TParam (Cst.TypeParam p) -> pure (text ("jsonCodec_param_" <> p))
      Ast.TType tt -> jsonCodec tt true
  pure (internalRef decl ("jsonCodec_" <> typ) pp)

qualify :: Maybe String -> String -> String
qualify path name = maybe name (_ <> "." <> name) path

externalRef :: String -> Codegen Box
externalRef s = fromMaybe (text s # pure) (splitType s <#> externalType)

emitRuntime :: Box -> Codegen Box
emitRuntime b = emit { mod: "Ccap.Codegen.Runtime", typ: Nothing, alias: Just "R" } b

newtypeJsonCodec :: Ast.Typ -> Codegen Box
newtypeJsonCodec t = do
  i <- jsonCodec t true
  emitRuntime $ text "R.codec_newtype" <<+>> i

externalJsonCodec :: Ast.Typ -> String -> String -> Codegen Box
externalJsonCodec t decode encode = do
  i <- jsonCodec t true
  decode_ <- externalRef decode
  encode_ <- externalRef encode
  emitRuntime $ text "R.codec_custom" <<+>> decode_ <<+>> encode_ <<+>> i

codecName :: Maybe String -> String -> String
codecName mod t = qualify mod $ "jsonCodec_" <> t

jsonCodec :: Ast.Typ -> Boolean -> Codegen Box
jsonCodec ty includeParensIfNeeded = do
  let
    tycon :: String -> Box -> Box
    tycon which ref = do
      text (codecName (Just "R") which <> " ") <<>> ref
  result <- case ty of
    Ast.Primitive p ->
      pure
        ( text
            $ codecName (Just "R")
                ( case p of
                    Cst.PBoolean -> "boolean"
                    Cst.PInt -> "int"
                    Cst.PDecimal -> "decimal"
                    Cst.PSmallInt -> "short"
                    Cst.PString -> "string"
                    Cst.PStringValidationHack -> "string"
                    Cst.PJson -> "json"
                )
        )
    Ast.Array (Ast.TType t) -> do
      ref <- jsonCodec t true
      pure (tycon "array" ref)
    Ast.Array (Ast.TParam (Cst.TypeParam p)) -> pure (tycon "array" (text ("jsonCodec_param_" <> p)))
    Ast.Option (Ast.TType t) -> do
      ref <- jsonCodec t true
      pure (tycon "maybe" ref)
    Ast.Option (Ast.TParam (Cst.TypeParam p)) -> pure (tycon "maybe" (text ("jsonCodec_param_" <> p)))
    Ast.Ref { decl, typ, params } -> internalCodecRef decl params typ
  pure
    ( if includeParensIfNeeded && needsParens ty then
        parens result
      else
        result
    )

parens :: Box -> Box
parens b = char '(' <<>> b <<>> char ')'

declForAll :: Array Cst.TypeParam -> String
declForAll typeParams =
  if Array.null typeParams then
    ""
  else
    " forall " <> intercalate " " (map (\(Cst.TypeParam p) -> p) typeParams) <> "."

declParamTypes :: Array Cst.TypeParam -> String
declParamTypes typeParams = do
  declForAll typeParams <> " " <> fold (map (\(Cst.TypeParam p) -> "R.JsonCodec " <> p <> " -> ") typeParams)

declParams :: String -> Array Cst.TypeParam -> String
declParams name typeParams =
  if Array.null typeParams then
    name
  else
    "(" <> name <> " " <> intercalate " " (map (\(Cst.TypeParam p) -> p) typeParams) <> ")"

defParams :: Array Cst.TypeParam -> String
defParams typeParams =
  if Array.null typeParams then
    ""
  else
    " " <> intercalate " " (map (\(Cst.TypeParam p) -> "jsonCodec_param_" <> p) typeParams)

defJsonCodec :: String -> Array Cst.TypeParam -> Box -> Box
defJsonCodec name typeParams def =
  let
    cname = codecName Nothing name
  in
    text cname <<+>> text ("::" <> declParamTypes typeParams <> "R.JsonCodec") <<+>> text (declParams name typeParams)
      // (text (cname <> defParams typeParams) <<+>> char '=')
      // indented def

record :: NonEmptyArray Ast.RecordProp -> Codegen Box
record props = do
  tell [ { mod: "Data.Tuple", typ: Nothing, alias: Just "T" } ]
  types <-
    for props $ _.typ
      >>> case _ of
          Ast.TParam (Cst.TypeParam p) -> pure (text p)
          Ast.TType t -> tyType t false
  let
    labels = props <#> \{ name } -> text name <<+>> text "::"
  pure $ delimitedLiteral Vert '{' '}' (NonEmptyArray.toArray (NonEmptyArray.zip labels types <#> \(Tuple l t) -> l <<+>> t))

recordDecoderApi :: NonEmptyArray Ast.RecordProp -> Codegen Box
recordDecoderApi props = do
  labelsAndTypes <-
    map (compact <<< NonEmptyArray.toArray)
      ( for props \{ name, typ } -> case typ of
          Ast.TParam (Cst.TypeParam p) -> pure (Just (text ("jsonCodec_" <> name <> " :: R.JsonCodec " <> p)))
          Ast.TType t ->
            if hasDecoderFastPath t then
              pure Nothing
            else do
              tt <- tyType t true
              pure (Just (text ("jsonCodec_" <> name) <<+>> text "::" <<+>> text "R.JsonCodec" <<+>> tt))
      )
  if Array.null labelsAndTypes then do
    tell
      [ { mod: "Data.Either", typ: Nothing, alias: Just "E" }
      , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError", alias: Nothing }
      ]
    pure (text "R.StandardDecoderApi")
  else do
    tell
      [ { mod: "Prelude", typ: Nothing, alias: Nothing }
      , { mod: "Data.Either", typ: Nothing, alias: Just "E" }
      , { mod: "Data.Maybe", typ: Nothing, alias: Just "M" }
      , { mod: "Data.Bifunctor", typ: Nothing, alias: Just "B" }
      , { mod: "Ccap.Codegen.Runtime", typ: Nothing, alias: Just "R" }
      , { mod: "Data.Decimal", typ: Just "Decimal", alias: Nothing }
      , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError", alias: Nothing }
      , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError(..)", alias: Just "JDE" }
      ]
    pure (delimitedLiteral Vert '{' '}' (standard <> labelsAndTypes))
  where
  standard :: Array Box
  standard =
    map text
      [ "nothing :: forall a. M.Maybe a"
      , "just :: forall a. a -> M.Maybe a"
      , "isLeft :: forall a b. E.Either a b -> Boolean"
      , "fromRight :: forall a b. Partial => E.Either a b -> b"
      , "right :: forall a b. b -> E.Either a b"
      , "left :: forall a b. a -> E.Either a b"
      , "addErrorPrefix :: forall a. String -> E.Either JsonDecodeError a -> E.Either JsonDecodeError a"
      , "missingValue :: forall b. String -> E.Either JsonDecodeError b"
      , "typeMismatch :: forall b. String -> E.Either JsonDecodeError b"

      , "jsonCodec_primitive_decimal :: R.JsonCodec Decimal"
      ]

recordDecoderApiDecl :: NonEmptyArray Ast.RecordProp -> Codegen Box
recordDecoderApiDecl props = do
  labelsAndValues <-
    map (compact <<< NonEmptyArray.toArray)
      ( for props \{ name, typ } -> case typ of
          Ast.TParam (Cst.TypeParam p) -> pure (Just (text ("jsonCodec_" <> name) <<>> text (": jsonCodec_param_" <> p)))
          Ast.TType t ->
            if hasDecoderFastPath t then
              pure Nothing
            else do
              x <- jsonCodec t false
              pure (Just (text ("jsonCodec_" <> name) <<>> text ":" <<+>> x))
      )
  pure
    ( if Array.null labelsAndValues then
        text "R.standardDecoderApi"
      else
        delimitedLiteral Vert '{' '}' (standard <> labelsAndValues)
    )
  where
  standard :: Array Box
  standard =
    map text
      [ "nothing: M.Nothing"
      , "just: M.Just"
      , "isLeft: E.isLeft"
      , "fromRight: \\(E.Right v) -> v"
      , "right: E.Right"
      , "left: E.Left"
      , "addErrorPrefix: \\name -> B.lmap (JDE.Named name)"
      , "missingValue: \\name -> E.Left $ JDE.Named name JDE.MissingValue"
      , "typeMismatch: E.Left <<< JDE.TypeMismatch"
      , "jsonCodec_primitive_decimal: R.jsonCodec_decimal"
      ]

hasDecoderFastPath :: Ast.Typ -> Boolean
hasDecoderFastPath = isJust <<< fastPathDecoderType

recordJsonCodec :: String -> Array Cst.TypeParam -> NonEmptyArray Ast.RecordProp -> Codegen Box
recordJsonCodec name typeParams props = do
  tell
    [ { mod: "Data.Argonaut.Core", typ: Nothing, alias: Just "A" }
    , { mod: "Ccap.Codegen.Runtime", typ: Nothing, alias: Just "R" }
    , { mod: "Foreign.Object", typ: Nothing, alias: Just "FO" }
    , { mod: "Prelude", typ: Nothing, alias: Nothing }
    , { mod: "Data.Argonaut.Decode.Error", typ: Just "JsonDecodeError", alias: Nothing }
    ]
  encodeProps <- recordWriteProps props
  let
    encode =
      text "encode: \\p -> A.fromObject $"
        // indented
            ( text "FO.fromFoldable"
                // indented encodeProps
            )

    decode = text ("decode: decode_" <> name <> " (decoderApi_" <> name <> defParams typeParams <> ")")
  pure $ delimitedLiteral Vert '{' '}' [ decode, encode ]

recordWriteProps :: NonEmptyArray Ast.RecordProp -> Codegen Box
recordWriteProps props = do
  types <-
    for props \{ name, typ } -> do
      x <- case typ of
        Ast.TType t -> jsonCodec t true
        Ast.TParam (Cst.TypeParam p) -> pure (text ("jsonCodec_param_" <> p))
      pure $ text "T.Tuple" <<+>> text (show name) <<+>> parens (x <<>> text ".encode p." <<>> text name)
  pure $ delimitedLiteral Vert '[' ']' (NonEmptyArray.toArray types)
