module GetSchema
  ( main
  ) where

import Prelude
import Ccap.Codegen.Cst as Cst
import Ccap.Codegen.Database as Database
import Ccap.Codegen.GetSchemaConfig (GetSchemaConfig, getSchemaConfig)
import Ccap.Codegen.PrettyPrint as PrettyPrint
import Ccap.Codegen.Util (liftEffectSafely, processResult, scrubEolSpaces)
import Control.Monad.Except (ExceptT, except)
import Data.Either (Either(..), note)
import Data.Filterable (filter)
import Data.Foldable (traverse_)
import Data.Int (fromString) as Int
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Traversable (for)
import Database.PostgreSQL.Pool as Pool
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Class (liftEffect)
import Effect.Class.Console as Console
import Options.Applicative as OptParse

app :: GetSchemaConfig -> Effect Unit
app config =
  launchAff_
    $ processResult do
        let
          checkMaybeString = filter (\s -> String.length s > 0)

          table = checkMaybeString config.table
        poolConfig <- except (readPoolConfig config.database)
        let
          c =
            { table
            , poolConfig
            , getSchemaConfig: config
            }
        fromDb <- dbModules c
        traverse_ writeModule fromDb
  where
  readPoolConfig :: String -> Either String Pool.Configuration
  readPoolConfig s = fromParts parts
    where
    parts = String.split (String.Pattern ":") s

    poolConfig db = (Pool.defaultConfiguration db) { idleTimeoutMillis = Just 500 }

    fromParts [ host, port, db, user ] =
      portFromString port
        <#> \p ->
          (poolConfig db)
            { host = Just host
            , port = Just p
            , user = Just user
            }

    fromParts [ host, port, db, user, password ] =
      portFromString port
        <#> \p ->
          (poolConfig db)
            { host = Just host
            , port = Just p
            , user = Just user
            , password = Just password
            }

    fromParts _ = Left "Config parameter must be of the form <host>:<port>:<db>:<user>:<password> (password optional)"

    portFromString = note "Database port must be an integer" <<< Int.fromString

dbModules :: Config -> ExceptT String Aff (Maybe Cst.Module)
dbModules config@{ getSchemaConfig: { dbManagedColumns, scalaPkg, pursPkg } } = do
  pool <- liftEffect $ Pool.new config.poolConfig
  if config.getSchemaConfig.domains then
    Just <$> Database.domainModule pool { dbManagedColumns, scalaPkg, pursPkg }
  else
    for config.table $ Database.tableModule pool { dbManagedColumns, scalaPkg, pursPkg }

type Config =
  { table :: Maybe String
  , poolConfig :: Pool.Configuration
  , getSchemaConfig :: GetSchemaConfig
  }

prependNotice :: String -> String
prependNotice = ("// This file is automatically generated from DB schema. Do not edit.\n" <> _)

writeModule :: Cst.Module -> ExceptT String Aff Unit
writeModule = liftEffectSafely <<< print
  where
  print = Console.info <<< prependNotice <<< scrubEolSpaces <<< PrettyPrint.prettyPrint

main :: Effect Unit
main = do
  configuration <- OptParse.execParser $ OptParse.info getSchemaConfig (OptParse.fullDesc)
  app configuration
