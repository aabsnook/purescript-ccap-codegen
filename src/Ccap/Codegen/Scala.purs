module Ccap.Codegen.Scala
  ( outputSpec
  ) where

import Prelude
import Ccap.Codegen.Annotations as Annotations
import Ccap.Codegen.Ast as Ast
import Ccap.Codegen.Cst as Cst
import Ccap.Codegen.Parser.Export as Export
import Ccap.Codegen.Shared (DelimitedLiteralDir(..), OutputSpec, delimitedLiteral, indented)
import Control.Monad.Reader (Reader, asks, runReader)
import Data.Array (foldl, (:))
import Data.Array as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty as NonEmptyArray
import Data.Compactable (compact)
import Data.Foldable (class Foldable, intercalate)
import Data.Maybe (Maybe(..), fromMaybe, maybe, maybe')
import Data.Monoid (guard)
import Data.String as String
import Data.Traversable (for, traverse)
import Data.TraversableWithIndex (forWithIndex)
import Data.Tuple (Tuple(..))
import Node.Path (FilePath)
import Text.PrettyPrint.Boxes (Box, char, emptyBox, hcat, nullBox, punctuateH, render, text, vcat, vsep, (//), (<<+>>), (<<>>))
import Text.PrettyPrint.Boxes (left, top) as Boxes

type Env
  = { currentModule :: Ast.Module
    }

type Codegen
  = Reader Env

runCodegen :: forall a. Env -> Codegen a -> a
runCodegen = flip runReader

outputSpec :: OutputSpec
outputSpec =
  { render: Just <<< render <<< oneModule
  , filePath: modulePath
  }

modulePath :: Ast.Module -> FilePath
modulePath (Ast.Module mod) = Export.toPath mod.exports.scalaPkg <> ".scala"

oneModule :: Ast.Module -> Box
oneModule mod@(Ast.Module { types }) = do
  let
    modDecl = primaryClass mod

    env =
      { currentModule: mod
      }

    body =
      runCodegen env do
        modDeclOutput <- traverse (typeDecl TopLevelCaseClass) modDecl
        declsOutput <- traverse (typeDecl CompanionObject) types
        pure
          $ Array.fromFoldable modDeclOutput
          <> [ text ("object " <> objectName mod <> " {") ]
          <> (NonEmptyArray.toArray declsOutput <#> indented)
          <> [ char '}' ]
  vsep 1 Boxes.left do
    [ text "// This file is automatically generated. Do not edit."
    , text ("package " <> classPackage mod)
    , imports mod
    ]
      <> body

typeParams :: Array Cst.TypeParam -> String
typeParams params =
  if Array.null params then
    ""
  else
    "[" <> intercalate ", " (map (\(Cst.TypeParam p) -> initialUpper p) params) <> "]"

objectName :: Ast.Module -> String
objectName (Ast.Module { exports: { scalaPkg } }) = fromMaybe scalaPkg $ Array.last $ Export.split scalaPkg

classPackage :: Ast.Module -> String
classPackage (Ast.Module { exports: { scalaPkg } }) = maybe scalaPkg Export.join $ Array.init $ Export.split scalaPkg

curly :: forall f. Foldable f => Functor f => Box -> f Box -> Box
curly pref inner = vcat Boxes.left (pref <<+>> char '{' : (Array.fromFoldable (indented <$> inner)) `Array.snoc` char '}')

paren :: forall f. Foldable f => Functor f => Box -> f Box -> Box
paren pref inner = vcat Boxes.left (pref <<>> char '(' : (Array.fromFoldable (indented <$> inner)) `Array.snoc` char ')')

paren_ :: forall f. Foldable f => Functor f => Box -> f Box -> Box -> Box
paren_ pref inner suffix = vcat Boxes.left (pref <<>> char '(' : (Array.fromFoldable (indented <$> inner)) `Array.snoc` (char ')' <<>> suffix))

-- Like `paren`, but outputs on a sigle line.
paren1 :: Box -> Array Box -> Box
paren1 pref inner = hcat Boxes.top (pref <<>> char '(' : inner `Array.snoc` char ')')

standardImports :: Array String
standardImports =
  [ "gov.wicourts.jsoncommon.Encoder"
  , "gov.wicourts.jsoncommon.Decoder"
  , "cats.Monad"
  ]

imports :: Ast.Module -> Box
imports mod@(Ast.Module m) =
  let
    pkg = classPackage mod

    samePkg impt = classPackage impt == pkg

    impts = (\(Ast.Module r) -> r.exports.scalaPkg) <$> Array.filter (not <<< samePkg) m.imports

    all = impts <> standardImports # Array.sort >>> Array.nub
  in
    vcat Boxes.left (all <#> \s -> text ("import " <> s))

defEncoder :: Boolean -> String -> Array Cst.TypeParam -> Box -> Box
defEncoder includeName name pp enc =
  let
    includedName = if includeName then name else ""

    typeParamParameters :: String
    typeParamParameters =
      if Array.null pp then
        ""
      else
        "("
          <> intercalate ", "
              ( map (\(Cst.TypeParam p) -> "jsonEncoder_param_" <> initialUpper p <> ": Encoder[" <> initialUpper p <> ", argonaut.Json]") pp
              )
          <> ")"
  in
    text ("def jsonEncoder" <> includedName <> typeParams pp <> typeParamParameters <> ": Encoder[" <> name <> typeParams pp <> ", argonaut.Json] =")
      // indented enc

defDecoder :: Boolean -> String -> Ast.ScalaDecoderType -> Box -> Box
defDecoder includeName name dType dec =
  let
    includedName = if includeName then name else ""
  in
    text ("def jsonDecoder" <> includedName <> typeParams ([ Cst.TypeParam "M[_]: Monad" ]) <> ": Decoder." <> decoderType dType <> "[M, " <> name <> "] =")
      // indented dec

wrapEncoder :: String -> Array Cst.TypeParam -> Ast.Type -> Box -> Codegen Box
wrapEncoder name pp t enc = do
  e <- encoder t
  pure $ defEncoder true name pp ((e <<>> text ".compose") `paren` [ enc ])

wrapDecoder :: Array Cst.Annotation -> String -> Ast.ScalaDecoderType -> Ast.Type -> Box -> Codegen Box
wrapDecoder annots name dType t dec = do
  topDec <- decoder annots t
  let
    body = (topDec <<>> text ".toEither.andThen") `paren` [ dec ] // text ".toValidated"
  pure $ defDecoder true name dType body

data TypeDeclOutputMode
  = TopLevelCaseClass
  | CompanionObject

derive instance eqTypeDeclOutputMode :: Eq TypeDeclOutputMode

noGenericParameters :: Box
noGenericParameters = text "// Scala decoders that involve parameterized types are not supported"

typeDecl :: TypeDeclOutputMode -> Ast.TypeDecl -> Codegen Box
typeDecl outputMode (Ast.TypeDecl { name, topType: tt, annots: an, params: pp, scalaDecoderType }) = case tt of
  Ast.Type t -> do
    ty <- typeDef outputMode t
    e <- encoder t
    d <-
      maybe'
        (\_ -> pure noGenericParameters)
        (\dType -> map (defDecoder true name dType) (decoder an t))
        scalaDecoderType
    pure
      $ text "type"
      <<+>> text name
      <<>> text (typeParams pp)
      <<+>> char '='
      <<+>> ty
      // defEncoder true name pp e
      // d
  Ast.Wrap t -> do
    case Annotations.getWrapOpts "scala" an of
      Nothing -> do
        ty <- typeDef outputMode t
        e <- encoder t
        d <-
          maybe'
            (\_ -> pure noGenericParameters)
            (\dType -> map (\b -> defDecoder true name dType (b <<>> text ".tagged")) (decoder an t))
            scalaDecoderType
        let
          tagname = text (name <> "T")

          scalatyp = text "gov.wicourts.common.@@[" <<>> ty <<>> char ',' <<+>> tagname <<>> char ']'
        pure
          $ vcat Boxes.left
              [ text "final abstract class" <<+>> tagname
              , text "type" <<+>> text name <<+>> char '=' <<+>> scalatyp
              , text "val" <<+>> text name <<>> char ':' <<+>> text "gov.wicourts.common.Tag.TagOf["
                  <<>> tagname
                  <<>> text "] = gov.wicourts.common.Tag.of["
                  <<>> tagname
                  <<>> char ']'
              , defEncoder true name pp (e <<>> text ".tagged")
              , d
              ]
      Just { typ, decode, encode } -> do
        wrappedEncoder <- wrapEncoder name pp t (text encode)
        wrappedDecoder <-
          maybe'
            (\_ -> pure noGenericParameters)
            (\dType -> wrapDecoder an name dType t (text decode <<>> text ".toEither"))
            scalaDecoderType
        pure
          $ text "type"
          <<+>> text name
          <<+>> char '='
          <<+>> text typ
          // wrappedEncoder
          // wrappedDecoder
  Ast.Record props -> do
    mod <- asks _.currentModule
    recordFieldTypes <- traverse (recordFieldType outputMode) props
    recordFieldEncoders <- traverse recordFieldEncoder props
    let
      modName = objectName mod

      cls = (text "final case class" <<+>> text (name <> typeParams pp)) `paren` recordFieldTypes

      enc = defEncoder (modName /= name) name pp (text "x => argonaut.Json.obj" `paren` recordFieldEncoders)
    dec <-
      maybe'
        (\_ -> pure noGenericParameters)
        ( \dType ->
            map (defDecoder (modName /= name) name dType)
              ( case NonEmptyArray.length props of
                  1 -> singletonRecordDecoder name (NonEmptyArray.head props)
                  x
                    | x <= 12 -> smallRecordDecoder name props
                  x -> largeRecordDecoder name props
              )
        )
        scalaDecoderType
    let
      fieldNamesTarget =
        if modName == name then
          Nothing
        else
          Just name

      names = fieldNames fieldNamesTarget (props <#> _.name)

      output
        | modName == name && outputMode == TopLevelCaseClass = cls

      output
        | modName == name && outputMode == CompanionObject = enc // dec // names

      output
        | otherwise = cls // enc // dec // names
    pure output
  Ast.Sum constructors ->
    maybe
      ( do
          let
            trait =
              if NonEmptyArray.length constructors > 1 then
                text "sealed trait" <<+>> text (name <> typeParams pp)
              else
                text ""
          cs <-
            if NonEmptyArray.length constructors == 1 then
              dataConstructor outputMode name pp false (NonEmptyArray.head constructors)
            else do
              ccc <- traverse (dataConstructor outputMode name pp true) constructors
              pure (text ("object " <> name) `curly` ccc)
          e <- sumTypeEncoder name pp constructors
          d <-
            maybe'
              (\_ -> pure noGenericParameters)
              (\dType -> map (defDecoder true name dType) (sumTypeDecoder name constructors))
              scalaDecoderType
          pure
            ( trait
                // cs
                // defEncoder true name pp e
                // d
            )
      )
      ( \vs -> do
          let
            trait = (text "sealed trait" <<+>> text name) `curly` [ text "def tag: String" ]

            variants =
              vs
                <#> \v ->
                    text ("case object " <> v <> " extends " <> name)
                      `curly`
                        [ text ("override def tag: String = " <> show v) ]

            assocs =
              vs
                <#> \v ->
                    paren1 (emptyBox 0 0) [ text (show v), text ", ", text name <<>> char '.' <<>> text v ] <<>> char ','

            params = text (show name) <<>> char ',' NonEmptyArray.: assocs
          enc <- wrapEncoder name pp (Ast.Primitive Cst.PString) (text "_.tag")
          dec <-
            wrapDecoder
              an
              name
              Ast.Field
              (Ast.Primitive Cst.PString)
              (((text ("Decoder.enum[M, " <> name) <<>> char ']') `paren` params) // text ".toEither")
          pure $ trait // ((text "object" <<+>> text name) `curly` variants) // enc // dec
      )
      (Ast.noArgConstructorNames constructors)

sumTypeEncoder :: String -> Array Cst.TypeParam -> NonEmptyArray Ast.Constructor -> Codegen Box
sumTypeEncoder name pp constructors = do
  let
    withName :: String -> String
    withName s =
      if NonEmptyArray.length constructors == 1 then
        s
      else
        name <> "." <> s
  branches <-
    for constructors case _ of
      Ast.NoArg (Cst.ConstructorName n) ->
        pure
          ( if Array.null pp then
              text ("case " <> withName n <> " => Encoder.constructor(" <> show n <> ", Nil)")
            else
              text ("case " <> withName n <> "() => Encoder.constructor(" <> show n <> ", Nil)")
          )
      Ast.WithArgs (Cst.ConstructorName n) args -> do
        parts <-
          forWithIndex args \i c -> case c of
            Ast.TParam (Cst.TypeParam p) -> pure (text ("jsonEncoder_param_" <> initialUpper p <> ".encode(param_" <> show i <> ")"))
            Ast.TType t -> do
              enc <- encoder t
              pure (enc <<>> text (".encode(param_" <> show i <> ")"))
        pure
          ( text
              ( "case "
                  <> withName n
                  <> "("
                  <> intercalate ", " (map (\r -> "param_" <> show r) (Array.range 0 (NonEmptyArray.length args - 1)))
                  <> ") => Encoder.constructor("
                  <> show n
                  <> ", List("
              )
              <<>> punctuateH Boxes.top (text ", ") parts
              <<>> text "))"
          )
  pure
    ( text "_ match " `curly` branches
    )

sumTypeDecoder :: String -> NonEmptyArray Ast.Constructor -> Codegen Box
sumTypeDecoder name constructors = do
  let
    withName :: String -> String
    withName s =
      if NonEmptyArray.length constructors == 1 then
        s
      else
        name <> "." <> s

    curly0 :: Box -> Array Box -> Box
    curly0 pref inner = vcat Boxes.left (pref <<+>> char '{' : (indented <$> inner) `Array.snoc` text "}.validation")
  branches <-
    for constructors case _ of
      Ast.NoArg (Cst.ConstructorName n) -> pure (text ("case (" <> show n <> ", Nil) => Decoder.construct0(" <> withName n <> ")"))
      Ast.WithArgs (Cst.ConstructorName n) args -> do
        parts <-
          forWithIndex args \i c -> case c of
            Ast.TParam (Cst.TypeParam p) -> pure (text "(not implemented)")
            Ast.TType t -> do
              dec <- decoder [] t
              pure (dec <<>> text (".param(" <> show i <> ", param_" <> show i <> ")"))
        let
          all =
            indented
              ( text ("Decoder.construct" <> show (NonEmptyArray.length args) <> "(")
                  // indented (punctuateH Boxes.top (text ", ") (text (show n) NonEmptyArray.: parts))
                  // text (")(" <> withName n <> ".apply" <> ")")
              )
        pure
          ( text
              ( "case ("
                  <> show n
                  <> ", List("
                  <> intercalate ", " (map (\r -> "param_" <> show r) (Array.range 0 (NonEmptyArray.length args - 1)))
                  <> ")) => "
              )
              // all
          )
  let
    -- XXX Awful, but there doesn't seem to be a better option besides a big boom
    failureBranch = text ("case (n, l) => sys.error(s\"Match error on type " <> name <> " for constructor $n with ${l.length} parameters\")")

    func =
      text ("val d: Decoder.Form[M, " <> name <> "] =")
        // indented (text "p match" `curly` (branches `NonEmptyArray.snoc` failureBranch))
        // text "d.toEither"
  pure
    ( text "Decoder.constructor.toEither.flatMap { p =>"
        // indented func
        // text "}.toValidated"
    )

dataConstructor :: TypeDeclOutputMode -> String -> Array Cst.TypeParam -> Boolean -> Ast.Constructor -> Codegen Box
dataConstructor outputMode name pp includeExtends = case _ of
  Ast.NoArg (Cst.ConstructorName n) ->
    pure
      ( if Array.null pp then
          text ("case object " <> n <> " extends " <> name)
        else
          text ("final case class " <> n <> typeParams pp <> "() extends " <> name <> typeParams pp)
      )
  Ast.WithArgs (Cst.ConstructorName n) args -> do
    params <-
      forWithIndex args \i c -> do
        ty <- case c of
          Ast.TParam (Cst.TypeParam p) -> pure (text (initialUpper p))
          Ast.TType ttt -> typeDef outputMode ttt
        pure (text ("param_" <> show i <> ": ") <<>> ty)
    pure
      ( text
          ( "final case class "
              <> n
              <> typeParams pp
              <> "("
          )
          <<>> punctuateH Boxes.top (text ", ") params
          <<>> text ")"
          <<>> if includeExtends then text (" extends " <> name <> typeParams pp) else text ""
      )

fieldNames :: Maybe String -> NonEmptyArray String -> Box
fieldNames mod names = maybe body (\m -> curly (text "object" <<+>> text m) [ body ]) mod
  where
  body = curly (text "object" <<+>> text "FieldNames") (names <#> fieldNameConst)

  fieldNameConst s = text "val" <<+>> text (initialUpper s) <<>> text ": String" <<+>> text "=" <<+>> text (show s)

initialUpper :: String -> String
initialUpper s =
  let
    { before, after } = String.splitAt 1 s
  in
    String.toUpper before <> after

primitive :: Cst.Primitive -> Box
primitive =
  text
    <<< case _ of
        Cst.PBoolean -> "Boolean"
        Cst.PInt -> "Int"
        Cst.PDecimal -> "BigDecimal"
        Cst.PString -> "String"
        Cst.PStringValidationHack -> "String"
        Cst.PJson -> "argonaut.Json"

generic :: String -> Box -> Box
generic typeName param = text typeName <<>> char '[' <<>> param <<>> char ']'

list :: Box -> Box
list = generic "List"

option :: Box -> Box
option = generic "Option"

typeDef :: TypeDeclOutputMode -> Ast.Type -> Codegen Box
typeDef mode = case _ of
  Ast.Ref tRef -> typeRef mode tRef
  Ast.Array (Ast.TType t) -> list <$> typeDef mode t
  Ast.Array (Ast.TParam (Cst.TypeParam p)) -> pure (list (text (initialUpper p)))
  Ast.Option (Ast.TType t) -> option <$> typeDef mode t
  Ast.Option (Ast.TParam (Cst.TypeParam p)) -> pure (option (text (initialUpper p)))
  Ast.Primitive p -> pure $ primitive p

typeRef :: TypeDeclOutputMode -> Ast.TRef -> Codegen Box
typeRef mode { decl, typ: typeName, params } = do
  currentModule <- asks _.currentModule
  refParams <-
    for params case _ of
      Ast.TParam (Cst.TypeParam p) -> pure (text (initialUpper p))
      Ast.TType t -> typeDef mode t
  let
    paramContent =
      if Array.null params then
        text ""
      else
        char '[' <<>> punctuateH Boxes.top (text ", ") refParams <<>> char ']'
  pure (maybe (internalTypeRef mode currentModule typeName) externalTypeRef decl <<>> paramContent)

internalTypeRef :: TypeDeclOutputMode -> Ast.Module -> String -> Box
internalTypeRef mode currentModule = case mode of
  TopLevelCaseClass -> text <<< prefix [ objectName currentModule ]
  CompanionObject -> text

externalTypeRef :: Tuple Ast.Module Ast.TypeDecl -> Box
externalTypeRef (Tuple importedModule importedType) =
  let
    scalaName = objectName importedModule

    typeName = Ast.typeDeclName importedType
  in
    text
      if needsQualifier scalaName importedType then
        prefix [ scalaName ] typeName
      else
        typeName

primaryClass :: Ast.Module -> Maybe Ast.TypeDecl
primaryClass mod@(Ast.Module { types }) = Array.find (\(Ast.TypeDecl { isPrimary }) -> isPrimary) types

isPrimaryClass :: String -> Ast.TypeDecl -> Boolean
isPrimaryClass modName typeD = modName == Ast.typeDeclName typeD && Ast.isRecord (Ast.typeDeclTopType typeD)

needsQualifier :: String -> Ast.TypeDecl -> Boolean
needsQualifier modName = not <<< isPrimaryClass modName

prefix :: Array String -> String -> String
prefix names = intercalate "." <<< Array.snoc names

encoder :: Ast.Type -> Codegen Box
encoder = case _ of
  Ast.Ref tRef@{ params } -> do
    refParams <-
      for params case _ of
        Ast.TParam (Cst.TypeParam p) -> pure (text ("jsonEncoder_param_" <> initialUpper p))
        Ast.TType t -> encoder t
    jsonTypeRef "Encoder" refParams tRef
  Ast.Array (Ast.TType t) -> encoder t <#> jsonList
  Ast.Array (Ast.TParam (Cst.TypeParam e)) -> pure (jsonList (text ("jsonEncoder_param_" <> initialUpper e)))
  Ast.Option (Ast.TType t) -> encoder t <#> jsonOption
  Ast.Option (Ast.TParam (Cst.TypeParam e)) -> pure (jsonOption (text ("jsonEncoder_param_" <> initialUpper e)))
  Ast.Primitive p -> pure $ text $ "Encoder" <> jsonPrimitive p

decoder :: Array Cst.Annotation -> Ast.Type -> Codegen Box
decoder annots = case _ of
  Ast.Ref tRef -> jsonTypeRef "Decoder" [] tRef
  Ast.Array (Ast.TType t) -> decoder annots t <#> jsonList
  Ast.Array (Ast.TParam (Cst.TypeParam e)) -> pure (jsonList (text ("jsonDecoder_param_" <> initialUpper e)))
  Ast.Option (Ast.TType t) -> decoder annots t <#> jsonOption
  Ast.Option (Ast.TParam (Cst.TypeParam e)) -> pure (jsonOption (text ("jsonDecoder_param_" <> initialUpper e)))
  Ast.Primitive p -> pure $ (text $ "Decoder" <> jsonPrimitive p) <<>> decoderValidations annots

jsonRef :: String -> String -> String
jsonRef which typ = "json" <> which <> typ -- should be blank if it is the primary class

jsonTypeRef :: String -> Array Box -> Ast.TRef -> Codegen Box
jsonTypeRef which params { decl, typ, isPrimaryRef } = do
  thisMod <- asks _.currentModule
  pure
    ( text
        ( maybe
            (jsonRef which (guard (not isPrimaryRef) typ))
            (\(Tuple m _) -> prefix [ objectName m ] (jsonRef which (guard (not isPrimaryRef) typ)))
            decl
        )
        <<>> if Array.null params then
            text ""
          else
            char '(' <<>> punctuateH Boxes.top (text ", ") params <<>> char ')'
    )

jsonList :: Box -> Box
jsonList json = json <<>> text ".list"

jsonOption :: Box -> Box
jsonOption json = json <<>> text ".option"

jsonPrimitive :: Cst.Primitive -> String
jsonPrimitive = case _ of
  Cst.PBoolean -> ".boolean"
  Cst.PInt -> ".int"
  Cst.PDecimal -> ".decimal"
  Cst.PString -> ".string"
  Cst.PStringValidationHack -> ".stringValidationHack"
  Cst.PJson -> ".json"

decoderValidations :: Array Cst.Annotation -> Box
decoderValidations annots = foldl (<<>>) nullBox validations
  where
  validations =
    compact
      [ maxLengthValidation <$> Annotations.getMaxLength annots
      , minLengthValidation <$> Annotations.getMinLength annots
      , maxSizeValidation <$> Annotations.getMaxSize annots
      , positiveValidation <$> Annotations.getIsPositive annots
      ]

maxLengthValidation :: String -> Box
maxLengthValidation max = text $ ".maxLength(" <> max <> ")"

minLengthValidation :: String -> Box
minLengthValidation min = text $ ".minLength(" <> min <> ")"

maxSizeValidation :: String -> Box
maxSizeValidation max = text $ ".maxSize(" <> max <> ")"

positiveValidation :: Unit -> Box
positiveValidation _ = text $ ".positive"

decoderType :: Ast.ScalaDecoderType -> String
decoderType = case _ of
  Ast.Field -> "Field"
  Ast.Form -> "Form"

encodeType :: Ast.Type -> Box -> Codegen Box
encodeType t e = encoder t <#> (_ <<>> text ".encode" `paren1` [ e ])

encodeTypeParam :: Cst.TypeParam -> Box -> Box
encodeTypeParam (Cst.TypeParam t) e = text ("jsonEncoder_param_" <> initialUpper t <> ".encode(") <<>> e <<>> char ')'

recordFieldType :: TypeDeclOutputMode -> Ast.RecordProp -> Codegen Box
recordFieldType mode { name, typ } = do
  ty <- case typ of
    Ast.TType t -> typeDef mode t
    Ast.TParam (Cst.TypeParam c) -> pure (text (initialUpper c))
  pure $ text name <<>> char ':' <<+>> ty <<>> char ','

recordFieldEncoder :: Ast.RecordProp -> Codegen Box
recordFieldEncoder { name, typ } = do
  ty <- case typ of
    Ast.TType t -> encodeType t (text ("x." <> name))
    Ast.TParam t -> pure (encodeTypeParam t (text ("x." <> name)))
  pure $ text (show name <> " ->") <<+>> ty <<>> char ','

recordFieldDecoder :: Ast.RecordProp -> Codegen Box
recordFieldDecoder { name, typ, annots } = case typ of
  Ast.TType t -> decoder annots t <#> (_ <<>> recordFieldProperty name)
  Ast.TParam _ -> pure (text "(not implemented)")

recordFieldProperty :: String -> Box
recordFieldProperty name = text ".property(" <<>> text (show name) <<>> char ')'

singletonRecordDecoder :: String -> Ast.RecordProp -> Codegen Box
singletonRecordDecoder name prop = recordFieldDecoder prop <#> (_ <<>> text (".map(" <> name <> ".apply)"))

smallRecordDecoder :: String -> NonEmptyArray Ast.RecordProp -> Codegen Box
smallRecordDecoder name props = do
  ps <- traverse (\r -> recordFieldDecoder r <#> (_ <<>> char ',')) props
  pure
    $ paren_
        (text ("cats.Apply[Decoder.Form[M, *]].map" <> show (NonEmptyArray.length props)))
        ps
        (text ("(" <> name <> ".apply)"))

-- | tree type for bulding cats Apply statements
data TupleApplyStatement
  = Final (Array Ast.RecordProp)
  | Intermediate (Array TupleApplyStatement)

largeRecordDecoder :: String -> NonEmptyArray Ast.RecordProp -> Codegen Box
largeRecordDecoder name nelProps = buildApplyStatement tupleStatements
  where
  -- XXX A compromise considering the late hour
  props = NonEmptyArray.toArray nelProps

  -- | collects all the props into a tree that can be parsed into cats.Apply statements
  tupleStatements :: Array TupleApplyStatement
  tupleStatements = go (Final <$> chunksOf 5 props)
    where
    go statements
      | Array.length statements > 12 = go (Intermediate <$> chunksOf 5 statements)

    go statements = statements

  -- | builds the Apply statements. The recursive funcion `go` returns a record with the two parts of
  -- | the syntax that need to be nested:
  -- | 1. the arguments to cats.Apply.tupleN (decoderDefinitionSyntax)
  -- | 2. the syntax to extract the values from the tuples (extractionSyntax)
  buildApplyStatement :: Array TupleApplyStatement -> Codegen Box
  buildApplyStatement statements =
    let
      recursionResults = go <$> statements
    in
      do
        decs <- traverse _.decoderDefinitionSyntax recursionResults
        pure
          $ paren_
              (text ("cats.Apply[Decoder.Form[M, *]].map" <> show (Array.length statements)))
              decs
              (curly (emptyBox 0 0) [ applyAllParams (recursionResults <#> _.extractionSyntax) ])
    where
    go (Final part) =
      if Array.length part == 1 then
        maybe
          ( { decoderDefinitionSyntax: pure (emptyBox 0 0)
            , extractionSyntax: emptyBox 0 0
            }
          )
          ( \r ->
              { decoderDefinitionSyntax:
                  (recordFieldDecoder r <#> (_ <<>> char ','))
              , extractionSyntax:
                  (text r.name) <<>> char ','
              }
          )
          (Array.head part)
      else
        { decoderDefinitionSyntax:
            do
              decs <- traverse (\r -> recordFieldDecoder r <#> (_ <<>> char ',')) part
              pure
                $ paren_
                    (text ("cats.Apply[Decoder.Form[M, *]].tuple" <> show (Array.length part)))
                    decs
                    (char ',')
        , extractionSyntax:
            (delimitedLiteral Horiz '(' ')' (part <#> _.name >>> text)) <<>> char ','
        }

    go (Intermediate parts) =
      let
        recursionResults = parts <#> go
      in
        { decoderDefinitionSyntax:
            do
              decs <- traverse (_.decoderDefinitionSyntax) recursionResults
              pure
                $ paren_
                    (text ("cats.Apply[Decoder.Form[M, *]].tuple" <> show (Array.length parts)))
                    decs
                    (char ',')
        , extractionSyntax:
            paren_
              (emptyBox 0 0)
              (recursionResults <#> _.extractionSyntax)
              (char ',')
        }

  applyAllParams :: Array Box -> Box
  applyAllParams statements =
    paren_
      (text "case ")
      statements
      (text " =>" // indented applyAllConstructor)
    where
    applyAllConstructor = paren (text name) (props <#> \{ name: n } -> text (n <> " = " <> n <> ","))

chunksOf :: forall a. Int -> Array a -> Array (Array a)
chunksOf n as =
  Array.range 0 ((Array.length as - 1) / n)
    <#> \i ->
        Array.slice (i * n) (i * n + n) as
