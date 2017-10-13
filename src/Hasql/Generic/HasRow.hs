{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverlappingInstances  #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Hasql.Generic.HasRow
    ( HasRow
    , HasDField
    , HasDValue
    , mkRow
    , mkDField
    , mkDValue
    , gRow
    , gDEnumValue
    ) where

--------------------------------------------------------------------------------
import           BinaryParser
import           Control.Monad              (replicateM)
import qualified Data.Aeson.Types           as JSON
import           Data.ByteString            (ByteString)
import           Data.Functor.Contravariant
import           Data.Int                   (Int16, Int32, Int64)
import qualified Data.Map                   as Map
import           Data.Scientific            (Scientific)
import           Data.Text
import           Data.Time                  (Day, DiffTime, LocalTime,
                                             TimeOfDay, TimeZone, UTCTime)
import           Data.UUID                  (UUID)
import           Data.Vector                (Vector)
import qualified Data.Vector                as Vector
import           Data.Word                  (Word16, Word32, Word64)
import           Generics.SOP
import qualified GHC.Generics               as GHC
import           Hasql.Decoders
#if MIN_VERSION_postgresql_binary(0,12,1)
import qualified PostgreSQL.Binary.Decoding  as Decoder
#else
import qualified PostgreSQL.Binary.Decoder  as Decoder
#endif

--------------------------------------------------------------------------------
-- |
-- A type that can be decoded from a database row, using Hasql's `Row` decoder.
--
-- Your data type needs to derive GHC `GHC.Generics.Generic`, and using this derive
-- an instance of SOP `Generics.SOP.Generic`. From here you can derive an instance
-- of `HasRow`. This gives you access to a value `mkRow`, which you can use
-- to get a value of type `Hasql.Decoders.Row`.
--
-- @
-- {-\# DeriveGeneric #-}
--
-- import Data.Text (Text)
-- import Data.UUID (UUID)
-- import qualified GHC.Generics as GHC
-- import           Generics.SOP
-- import           Hasql.Query (statement)
-- import           Hasql.Session (Session, query)
-- import qualified Hasql.Decoders as HD
-- import qualified Hasql.Encoders as HE
--
-- data Person = Person
--   { personId :: UUID
--   , personName :: Text
--   , personAge :: Int
--   } deriving (GHC.Generic)
--
-- instance Generic Person
-- instance HasRow Person
--
-- \-- Search for a 'Person' with a matching UUID
-- findPerson :: UUID -> Session (Maybe Person)
-- findPerson pid =
--   query pid preparedStatement
--     where
--       preparedStatement = statement sql encoder decoder True
--       sql = "SELECT id, name, age FROM people WHERE id=$1"
--       encoder = HE.value HE.uuid
--       decoder = HD.maybeRow mkRow
-- @
class HasRow a where
  mkRow :: Row a
  default mkRow :: (Generic a, Code a ~ '[ xs ], All HasDField xs) => Row a
  mkRow = gRow

--------------------------------------------------------------------------------
-- | A type representing a value decoder lifted into a compasable `Row`. Instances
--   are defined that will lift `HasDValue` types into the common wrappers like
--   vectors, lists, and maybe.
class HasDField a where
  mkDField :: Row a

--------------------------------------------------------------------------------
-- | A type representing an individual value decoder. These should be defined
--   manually for each type.
class HasDValue a where
  mkDValue :: Value a

--------------------------------------------------------------------------------
-- | Generate a `Row` generically
gRow :: (Generic a, Code a ~ '[ xs ], All HasDField xs) => Row a
gRow =
    to . SOP . Z <$> hsequence (hcpure (Proxy :: Proxy HasDField) mkDField)

--------------------------------------------------------------------------------
class (a ~ b) => Equal a b
instance (a ~ b) => Equal a b

--------------------------------------------------------------------------------
-- | Derive a 'HasDField' for enumeration types
gDEnumValue :: (Generic a, All (Equal '[]) (Code a)) => NP (K Text) (Code a) -> Value a
gDEnumValue names = enum $ \n -> Map.lookup n table
  where
    table =
      Map.fromList
        (hcollapse
          (hczipWith (Proxy :: Proxy (Equal '[]))
            (\ (K n) (Fn c) -> K (n, to (SOP (unK (c Nil)))))
            names injections
          )
        )


--------------------------------------------------------------------------------
-- Instances for common data types

instance HasDValue Bool where
  {-# INLINE mkDValue #-}
  mkDValue = bool

instance HasDValue Int16 where
  {-# INLINE mkDValue #-}
  mkDValue = int2

instance HasDValue Int32 where
  {-# INLINE mkDValue #-}
  mkDValue = int4

instance HasDValue Int64 where
  {-# INLINE mkDValue #-}
  mkDValue = int8

instance HasDValue Word16 where
  {-# INLINE mkDValue #-}
  mkDValue = word2

instance HasDValue Word32 where
  {-# INLINE mkDValue #-}
  mkDValue = word4

instance HasDValue Word64 where
  {-# INLINE mkDValue #-}
  mkDValue = word8

instance HasDValue Float where
  {-# INLINE mkDValue #-}
  mkDValue = float4

instance HasDValue Double where
  {-# INLINE mkDValue #-}
  mkDValue = float8

instance HasDValue Scientific where
  {-# INLINE mkDValue #-}
  mkDValue = numeric

instance HasDValue Char where
  {-# INLINE mkDValue #-}
  mkDValue = char

instance HasDValue Text where
  {-# INLINE mkDValue #-}
  mkDValue = text

instance HasDValue ByteString where
  {-# INLINE mkDValue #-}
  mkDValue = bytea

instance HasDValue Day where
  {-# INLINE mkDValue #-}
  mkDValue = date

instance HasDValue LocalTime where
  {-# INLINE mkDValue #-}
  mkDValue = timestamp

instance HasDValue UTCTime where
  {-# INLINE mkDValue #-}
  mkDValue = timestamptz

instance HasDValue TimeOfDay where
  {-# INLINE mkDValue #-}
  mkDValue = time

instance HasDValue (TimeOfDay, TimeZone) where
  {-# INLINE mkDValue #-}
  mkDValue = timetz

instance HasDValue DiffTime where
  {-# INLINE mkDValue #-}
  mkDValue = interval

instance HasDValue UUID where
  {-# INLINE mkDValue #-}
  mkDValue = uuid

instance HasDValue JSON.Value where
  {-# INLINE mkDValue #-}
  mkDValue = jsonb


--------------------------------------------------------------------------------
instance HasDValue a => HasDField [Maybe a] where
  {-# INLINE mkDField #-}
  mkDField = value $ array (arrayDimension replicateM (arrayNullableValue mkDValue))

instance HasDValue a => HasDField [a] where
  {-# INLINE mkDField #-}
  mkDField = value $ array (arrayDimension replicateM (arrayValue mkDValue))

instance HasDValue a => HasDField (Vector (Maybe a)) where
  {-# INLINE mkDField #-}
  mkDField = value $ array (arrayDimension Vector.replicateM (arrayNullableValue mkDValue))

instance HasDValue a => HasDField (Vector a) where
  {-# INLINE mkDField #-}
  mkDField = value $ array (arrayDimension Vector.replicateM (arrayValue mkDValue))

instance HasDValue a => HasDField (Maybe a) where
  {-# INLINE mkDField #-}
  mkDField = nullableValue mkDValue

instance HasDValue a => HasDField a where
  {-# INLINE mkDField #-}
  mkDField = value mkDValue


--------------------------------------------------------------------------------
instance HasDField Int where
  {-# INLINE mkDField #-}
  mkDField = fmap fromIntegral (value int8)

instance HasDField (Maybe Int) where
  {-# INLINE mkDField #-}
  mkDField = fmap (fmap fromIntegral) (nullableValue int8)

--------------------------------------------------------------------------------
word2 :: Value Word16
word2 = custom $ \b -> BinaryParser.run Decoder.int

--------------------------------------------------------------------------------
word4 :: Value Word32
word4 = custom $ \b -> BinaryParser.run Decoder.int

--------------------------------------------------------------------------------
word8 :: Value Word64
word8 = custom $ \b -> BinaryParser.run Decoder.int

instance HasRow ()
instance (Code (a,b) ~ '[xs], All HasDField xs) => HasRow (a,b)
instance (Code (a,b,c) ~ '[xs], All HasDField xs) => HasRow (a,b,c)
instance (Code (a,b,c,d) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d)
instance (Code (a,b,c,d,e) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e)
instance (Code (a,b,c,d,e,f) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f)
instance (Code (a,b,c,d,e,f,g) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g)
instance (Code (a,b,c,d,e,f,g,h) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h)
instance (Code (a,b,c,d,e,f,g,h,i) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i)
instance (Code (a,b,c,d,e,f,g,h,i,j) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j)
instance (Code (a,b,c,d,e,f,g,h,i,j,k) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y)
instance (Code (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z) ~ '[xs], All HasDField xs) => HasRow (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z)
