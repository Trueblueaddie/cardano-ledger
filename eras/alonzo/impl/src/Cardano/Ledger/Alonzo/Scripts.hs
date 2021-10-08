{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
-- Needed for FromCBOR(Annotator CostModel)
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Ledger.Alonzo.Scripts
  ( Tag (..),
    Script (TimelockScript, PlutusScript),
    txscriptfee,
    ppTag,
    ppScript,
    isPlutusScript,
    pointWiseExUnits,

    -- * Cost Model
    CostModel (..),
    ExUnits (..),
    Prices (..),
    hashCostModel,
    validateCostModelParams,
    ppExUnits,
    ppCostModel,
    ppPrices,
    decodeCostModelMap,
    decodeCostModel,

    -- * Deprecated
    defaultCostModel,
    alwaysSucceeds,
    alwaysFails,
  )
where

import Cardano.Binary (DecoderError (..), FromCBOR (fromCBOR), ToCBOR (toCBOR), serialize')
import Cardano.Ledger.Alonzo.Language (Language (..))
import Cardano.Ledger.BaseTypes
import Cardano.Ledger.Coin (Coin (..))
import qualified Cardano.Ledger.Core as Core
import qualified Cardano.Ledger.Crypto as CC (Crypto)
import Cardano.Ledger.Era (Era (Crypto), ValidateScript (hashScript))
import Cardano.Ledger.Pretty
  ( PDoc,
    PrettyA (..),
    ppInteger,
    ppMap,
    ppNatural,
    ppRational,
    ppRecord,
    ppScriptHash,
    ppSexp,
    ppString,
    text,
  )
import Cardano.Ledger.SafeHash
  ( HashWithCrypto (..),
    SafeHash,
    SafeToHash (..),
  )
import Cardano.Ledger.ShelleyMA.Timelocks
import Control.DeepSeq (NFData (..))
import Control.Monad (when)
import Data.ByteString.Short (ShortByteString, fromShort)
import Data.Coders
import Data.DerivingVia (InstantiatedAt (..))
import Data.Int (Int64)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Measure (BoundedMeasure(..), Measure)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Typeable
import Data.Word (Word64, Word8)
import GHC.Generics (Generic)
import NoThunks.Class (InspectHeapNamed (..), NoThunks)
import Numeric.Natural (Natural)
import Plutus.V1.Ledger.Api as PV1 hiding (Map, Script)
import qualified Plutus.V1.Ledger.Examples as Plutus
  ( alwaysFailingNAryFunction,
    alwaysSucceedingNAryFunction,
  )
import Plutus.V2.Ledger.Api as PV2 hiding (Map, Script)
import qualified Prettyprinter as PP

-- | Marker indicating the part of a transaction for which this script is acting
-- as a validator.
data Tag
  = -- | Validates spending a script-locked UTxO
    Spend
  | -- | Validates minting new tokens
    Mint
  | -- | Validates certificate transactions
    Cert
  | -- | Validates withdrawl from a reward account
    Rewrd
  deriving (Eq, Generic, Ord, Show, Enum, Bounded)

instance NoThunks Tag

-- =======================================================

-- | Scripts in the Alonzo Era, Either a Timelock script or a Plutus script.
data Script era
  = TimelockScript (Timelock (Crypto era))
  | PlutusScript Language ShortByteString
  deriving (Eq, Generic, Ord)

instance (ValidateScript era, Core.Script era ~ Script era) => Show (Script era) where
  show (TimelockScript x) = "TimelockScript " ++ show x
  show s@(PlutusScript v _) = "PlutusScript " ++ show v ++ " " ++ show (hashScript @era s)

deriving via
  InspectHeapNamed "Script" (Script era)
  instance
    NoThunks (Script era)

instance NFData (Script era)

-- | Both constructors know their original bytes
instance SafeToHash (Script era) where
  originalBytes (TimelockScript t) = originalBytes t
  originalBytes (PlutusScript _ bs) = fromShort bs

{-# DEPRECATED alwaysSucceeds "import from Test.Cardano.Ledger.Alonzo.Scripts instead" #-}
alwaysSucceeds :: Language -> Natural -> Script era
alwaysSucceeds lang n = PlutusScript lang (Plutus.alwaysSucceedingNAryFunction n)

{-# DEPRECATED alwaysFails "import from Test.Cardano.Ledger.Alonzo.Scripts instead" #-}
alwaysFails :: Language -> Natural -> Script era
alwaysFails lang n = PlutusScript lang (Plutus.alwaysFailingNAryFunction n)

isPlutusScript :: Script era -> Bool
isPlutusScript (PlutusScript _ _) = True
isPlutusScript (TimelockScript _) = False

-- ===========================================

-- | Arbitrary execution unit in which we measure the cost of scripts.
data ExUnits = ExUnits
  { exUnitsMem :: !Natural,
    exUnitsSteps :: !Natural
  }
  deriving (Eq, Generic, Show)
  -- It is deliberate that there is no Ord instance, use `pointWiseExUnits` instead.
  deriving
    (Measure)
    via (InstantiatedAt Generic ExUnits)
  deriving
    (Monoid, Semigroup)
    via (InstantiatedAt Measure ExUnits)

instance BoundedMeasure ExUnits where
  maxBound = ExUnits (fromIntegral $ Prelude.maxBound @Word64) (fromIntegral $ Prelude.maxBound @Word64)

instance NoThunks ExUnits

instance NFData ExUnits

-- | It is deliberate that there is no `Ord` instance for `ExUnits`. Use this function
--   to compare if one `ExUnit` is pointwise compareable to another.
pointWiseExUnits :: (Natural -> Natural -> Bool) -> ExUnits -> ExUnits -> Bool
pointWiseExUnits oper (ExUnits m1 s1) (ExUnits m2 s2) = (m1 `oper` m2) && (s1 `oper` s2)

-- =====================================

newtype CostModel = CostModel (Map Text Integer)
  deriving (Eq, Generic, Show, Ord)

-- NOTE: Since cost model serializations need to be independently reproduced,
-- we use the 'canonical' serialization approach used in Byron.
instance ToCBOR CostModel where
  toCBOR (CostModel cm) = toCBOR $ Map.elems cm

instance SafeToHash CostModel where
  originalBytes = serialize'

-- CostModel does not determine 'crypto' so make a HashWithCrypto
-- rather than a HashAnotated instance.

instance HashWithCrypto CostModel CostModel

instance NoThunks CostModel

instance NFData CostModel

checkCostModel :: Language -> Map Text Integer -> Either String CostModel
checkCostModel PlutusV1 cm =
  if PV1.validateCostModelParams cm
    then Right (CostModel cm)
    else Left ("Invalid PlutusV1 cost model: " ++ show cm)
checkCostModel PlutusV2 cm =
  if PV2.validateCostModelParams cm
    then Right (CostModel cm)
    else Left ("Invalid PlutusV2 cost model: " ++ show cm)

defaultCostModel :: Language -> Maybe CostModel
defaultCostModel PlutusV1 = CostModel <$> PV1.defaultCostModelParams
defaultCostModel PlutusV2 = CostModel <$> PV2.defaultCostModelParams

decodeCostModelMap :: Decoder s (Map Language CostModel)
decodeCostModelMap = decodeMapByKey fromCBOR decodeCostModel

decodeCostModel :: Language -> Decoder s CostModel
decodeCostModel lang =
  case dcmps of
    Nothing -> fail "Default Plutus Cost Model is corrupt."
    Just dcm -> do
      checked <- checkCostModel lang <$> decodeArrayAsMap (Map.keysSet dcm) fromCBOR
      case checked of
        Left e -> fail e
        Right cm -> pure cm
  where
    dcmps = case lang of
      PlutusV1 -> PV1.defaultCostModelParams
      PlutusV2 -> PV2.defaultCostModelParams

decodeArrayAsMap :: Ord a => Set a -> Decoder s b -> Decoder s (Map a b)
decodeArrayAsMap keys decodeValue = do
  values <- decodeList decodeValue
  let numValues = length values
      numKeys = Set.size keys
  when (numValues /= numKeys) $
    fail $
      "Expected array with " <> show numKeys
        <> " entries, but encoded array has "
        <> show numValues
        <> " entries."
  pure $ Map.fromList $ zip (Set.toAscList keys) values

-- CostModel is not parameterized by Crypto or Era so we use the
-- hashWithCrypto function, rather than hashAnnotated

hashCostModel ::
  forall e.
  Era e =>
  Proxy e ->
  CostModel ->
  SafeHash (Crypto e) CostModel
hashCostModel _proxy = hashWithCrypto (Proxy @(Crypto e))

-- ==================================

-- | Prices per execution unit
data Prices = Prices
  { prMem :: !NonNegativeInterval,
    prSteps :: !NonNegativeInterval
  }
  deriving (Eq, Generic, Show, Ord)

instance NoThunks Prices

instance NFData Prices

-- | Compute the cost of a script based upon prices and the number of execution
-- units.
txscriptfee :: Prices -> ExUnits -> Coin
txscriptfee Prices {prMem, prSteps} ExUnits {exUnitsMem, exUnitsSteps} =
  Coin $
    ceiling $
      (fromIntegral exUnitsMem * unboundRational prMem)
        + (fromIntegral exUnitsSteps * unboundRational prSteps)

--------------------------------------------------------------------------------
-- Serialisation
--------------------------------------------------------------------------------

tagToWord8 :: Tag -> Word8
tagToWord8 = toEnum . fromEnum

word8ToTag :: Word8 -> Maybe Tag
word8ToTag e
  | fromEnum e > fromEnum (Prelude.maxBound :: Tag) = Nothing
  | fromEnum e < fromEnum (minBound :: Tag) = Nothing
  | otherwise = Just $ toEnum (fromEnum e)

instance ToCBOR Tag where
  toCBOR = toCBOR . tagToWord8

instance FromCBOR Tag where
  fromCBOR =
    word8ToTag <$> fromCBOR >>= \case
      Nothing -> cborError $ DecoderErrorCustom "Tag" "Unknown redeemer tag"
      Just n -> pure n

instance ToCBOR ExUnits where
  toCBOR (ExUnits m s) = encode $ Rec ExUnits !> To m !> To s

instance FromCBOR ExUnits where
  fromCBOR = decode $ RecD ExUnits <! D decNat <! D decNat
    where
      decNat :: Decoder s Natural
      decNat = do
        x <- fromCBOR
        when
          (x > fromIntegral (Prelude.maxBound :: Int64))
          ( cborError $
              DecoderErrorCustom "ExUnits field" "values must not exceed maxBound :: Int64"
          )
        pure $ wordToNatural x
      wordToNatural :: Word64 -> Natural
      wordToNatural = fromIntegral

instance ToCBOR Prices where
  toCBOR (Prices m s) = encode $ Rec Prices !> To m !> To s

instance FromCBOR Prices where
  fromCBOR = decode $ RecD Prices <! From <! From

instance forall era. (Typeable (Crypto era), Typeable era) => ToCBOR (Script era) where
  toCBOR x = encode (encodeScript x)

encodeScript :: (Typeable (Crypto era)) => Script era -> Encode 'Open (Script era)
encodeScript (TimelockScript i) = Sum TimelockScript 0 !> To i
encodeScript (PlutusScript PlutusV1 s) = Sum (PlutusScript PlutusV1) 1 !> To s -- Use the ToCBOR instance of ShortByteString
encodeScript (PlutusScript PlutusV2 s) = Sum (PlutusScript PlutusV1) 2 !> To s

instance
  (CC.Crypto (Crypto era), Typeable (Crypto era), Typeable era) =>
  FromCBOR (Annotator (Script era))
  where
  fromCBOR = decode (Summands "Alonzo Script" decodeScript)
    where
      decodeScript :: Word -> Decode 'Open (Annotator (Script era))
      decodeScript 0 = Ann (SumD TimelockScript) <*! From
      decodeScript 1 = Ann (SumD $ PlutusScript PlutusV1) <*! Ann From
      decodeScript 2 = Ann (SumD $ PlutusScript PlutusV2) <*! Ann From
      decodeScript n = Invalid n

-- ============================================================
-- Pretty printing versions

ppTag :: Tag -> PDoc
ppTag x = ppString (show x)

instance PrettyA Tag where prettyA = ppTag

ppScript :: forall era. (ValidateScript era, Core.Script era ~ Script era) => Script era -> PDoc
ppScript s@(PlutusScript v _) = ppString ("PlutusScript " <> show v <> " ") PP.<+> ppScriptHash (hashScript @era s)
ppScript (TimelockScript x) = ppTimelock x

instance (ValidateScript era, Core.Script era ~ Script era) => PrettyA (Script era) where prettyA = ppScript

ppExUnits :: ExUnits -> PDoc
ppExUnits (ExUnits mem step) =
  ppRecord "ExUnits" [("memory", ppNatural mem), ("steps", ppNatural step)]

instance PrettyA ExUnits where prettyA = ppExUnits

ppCostModel :: CostModel -> PDoc
ppCostModel (CostModel m) =
  ppSexp "CostModel" [ppMap text ppInteger m]

instance PrettyA CostModel where prettyA = ppCostModel

ppPrices :: Prices -> PDoc
ppPrices Prices {prMem, prSteps} =
  ppRecord
    "Prices"
    [ ("prMem", ppRational $ unboundRational prMem),
      ("prSteps", ppRational $ unboundRational prSteps)
    ]

instance PrettyA Prices where prettyA = ppPrices