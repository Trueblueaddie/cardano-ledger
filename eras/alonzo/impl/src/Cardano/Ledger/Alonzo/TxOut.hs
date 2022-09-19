{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Alonzo.TxOut
  ( AlonzoTxOut (.., AlonzoTxOut, TxOutCompact, TxOutCompactDH),
    AlonzoEraTxOut (..),
    -- Constructors are not exported for safety:
    Addr28Extra,
    DataHash32,
    getAdaOnly,
    decodeDataHash32,
    encodeDataHash32,
    encodeAddress28,
    decodeAddress28,
    viewCompactTxOut,
    viewTxOut,
    getAlonzoTxOutEitherAddr,
    utxoEntrySize,

    -- * Deprecated
    TxOut,
  )
where

import Cardano.Binary
  ( DecoderError (..),
    FromCBOR (..),
    ToCBOR (..),
    decodeBreakOr,
    decodeListLenOrIndef,
    encodeListLen,
  )
import Cardano.Crypto.Hash
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Data (Datum (..), dataHashSize)
import Cardano.Ledger.Alonzo.Era
import Cardano.Ledger.Alonzo.PParams.Class
import Cardano.Ledger.Alonzo.Scripts ()
import Cardano.Ledger.BaseTypes
  ( Network (..),
    StrictMaybe (..),
    maybeToStrictMaybe,
  )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.CompactAddress
  ( CompactAddr,
    compactAddr,
    decompactAddr,
    fromCborBackwardsBothAddr,
  )
import Cardano.Ledger.Compactible
import Cardano.Ledger.Core hiding (TxBody, TxOut)
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Credential (Credential (..), PaymentCredential, StakeReference (..))
import qualified Cardano.Ledger.Crypto as CC
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (..))
import Cardano.Ledger.SafeHash
  ( extractHash,
    unsafeMakeSafeHash,
  )
import Cardano.Ledger.Val
  ( DecodeNonNegative (decodeNonNegative),
    Val (..),
  )
import Control.DeepSeq (NFData (..), rwhnf)
import Control.Monad (guard, (<$!>))
import Data.Bits
import Data.Coders hiding (to)
import Data.Maybe (fromMaybe)
import Data.Sharing
import Data.Typeable (Proxy (..), (:~:) (Refl))
import Data.Word
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack)
import GHC.TypeLits
import Lens.Micro
import NoThunks.Class (InspectHeapNamed (..), NoThunks)
import Prelude hiding (lookup)

data Addr28Extra
  = Addr28Extra
      {-# UNPACK #-} !Word64 -- Payment Addr
      {-# UNPACK #-} !Word64 -- Payment Addr
      {-# UNPACK #-} !Word64 -- Payment Addr
      {-# UNPACK #-} !Word64 -- Payment Addr (32bits) + ... +  0/1 for Testnet/Mainnet + 0/1 Script/Pubkey
  deriving (Eq)

data DataHash32
  = DataHash32
      {-# UNPACK #-} !Word64 -- DataHash
      {-# UNPACK #-} !Word64 -- DataHash
      {-# UNPACK #-} !Word64 -- DataHash
      {-# UNPACK #-} !Word64 -- DataHash
  deriving (Eq)

decodeAddress28 ::
  forall c.
  HashAlgorithm (CC.ADDRHASH c) =>
  Credential 'Staking c ->
  Addr28Extra ->
  Maybe (Addr c)
decodeAddress28 stakeRef (Addr28Extra a b c d) = do
  Refl <- sameNat (Proxy @(SizeHash (CC.ADDRHASH c))) (Proxy @28)
  let network = if d `testBit` 1 then Mainnet else Testnet
      paymentCred =
        if d `testBit` 0
          then KeyHashObj (KeyHash addrHash)
          else ScriptHashObj (ScriptHash addrHash)
      addrHash :: Hash (CC.ADDRHASH c) a
      addrHash =
        hashFromPackedBytes $
          PackedBytes28 a b c (fromIntegral (d `shiftR` 32))
  pure $! Addr network paymentCred (StakeRefBase stakeRef)

data AlonzoTxOut era
  = TxOutCompact'
      {-# UNPACK #-} !(CompactAddr (EraCrypto era))
      !(CompactForm (Value era))
  | TxOutCompactDH'
      {-# UNPACK #-} !(CompactAddr (EraCrypto era))
      !(CompactForm (Value era))
      !(DataHash (EraCrypto era))
  | TxOut_AddrHash28_AdaOnly
      !(Credential 'Staking (EraCrypto era))
      {-# UNPACK #-} !Addr28Extra
      {-# UNPACK #-} !(CompactForm Coin) -- Ada value
  | TxOut_AddrHash28_AdaOnly_DataHash32
      !(Credential 'Staking (EraCrypto era))
      {-# UNPACK #-} !Addr28Extra
      {-# UNPACK #-} !(CompactForm Coin) -- Ada value
      {-# UNPACK #-} !DataHash32

type TxOut era = AlonzoTxOut era

{-# DEPRECATED TxOut "Use `AlonzoTxOut` instead" #-}

deriving stock instance
  ( Eq (Value era),
    Compactible (Value era)
  ) =>
  Eq (AlonzoTxOut era)

deriving instance Generic (AlonzoTxOut era)

-- | Already in NF
instance NFData (AlonzoTxOut era) where
  rnf = rwhnf

addressErrorMsg :: String
addressErrorMsg = "Impossible: Compacted an address of non-standard size"
{-# NOINLINE addressErrorMsg #-}

decodeDataHash32 ::
  forall c.
  HashAlgorithm (CC.HASH c) =>
  DataHash32 ->
  Maybe (DataHash c)
decodeDataHash32 (DataHash32 a b c d) = do
  Refl <- sameNat (Proxy @(SizeHash (CC.HASH c))) (Proxy @32)
  Just $! unsafeMakeSafeHash $ hashFromPackedBytes $ PackedBytes32 a b c d

viewCompactTxOut ::
  (Era era, Val (Value era)) =>
  AlonzoTxOut era ->
  (CompactAddr (EraCrypto era), CompactForm (Value era), StrictMaybe (DataHash (EraCrypto era)))
viewCompactTxOut txOut = case txOut of
  TxOutCompact' addr val -> (addr, val, SNothing)
  TxOutCompactDH' addr val dh -> (addr, val, SJust dh)
  TxOut_AddrHash28_AdaOnly stakeRef addr28Extra adaVal
    | Just addr <- decodeAddress28 stakeRef addr28Extra ->
      (compactAddr addr, injectCompact adaVal, SNothing)
    | otherwise -> error addressErrorMsg
  TxOut_AddrHash28_AdaOnly_DataHash32 stakeRef addr28Extra adaVal dataHash32
    | Just addr <- decodeAddress28 stakeRef addr28Extra,
      Just dh <- decodeDataHash32 dataHash32 ->
      (compactAddr addr, injectCompact adaVal, SJust dh)
    | otherwise -> error addressErrorMsg

viewTxOut ::
  (Era era, Val (Value era)) =>
  AlonzoTxOut era ->
  (Addr (EraCrypto era), Value era, StrictMaybe (DataHash (EraCrypto era)))
viewTxOut (TxOutCompact' bs c) = (addr, val, SNothing)
  where
    addr = decompactAddr bs
    val = fromCompact c
viewTxOut (TxOutCompactDH' bs c dh) = (addr, val, SJust dh)
  where
    addr = decompactAddr bs
    val = fromCompact c
viewTxOut (TxOut_AddrHash28_AdaOnly stakeRef addr28Extra adaVal)
  | Just addr <- decodeAddress28 stakeRef addr28Extra =
    (addr, inject (fromCompact adaVal), SNothing)
viewTxOut (TxOut_AddrHash28_AdaOnly_DataHash32 stakeRef addr28Extra adaVal dataHash32)
  | Just addr <- decodeAddress28 stakeRef addr28Extra,
    Just dh <- decodeDataHash32 dataHash32 =
    (addr, inject (fromCompact adaVal), SJust dh)
viewTxOut TxOut_AddrHash28_AdaOnly {} = error addressErrorMsg
viewTxOut TxOut_AddrHash28_AdaOnly_DataHash32 {} = error addressErrorMsg

instance (Era era, Val (Value era), Show (Value era)) => Show (AlonzoTxOut era) where
  show = show . viewTxOut -- FIXME: showing tuple is ugly

deriving via InspectHeapNamed "AlonzoTxOut" (AlonzoTxOut era) instance NoThunks (AlonzoTxOut era)

encodeAddress28 ::
  forall c.
  HashAlgorithm (CC.ADDRHASH c) =>
  Network ->
  PaymentCredential c ->
  Maybe (SizeHash (CC.ADDRHASH c) :~: 28, Addr28Extra)
encodeAddress28 network paymentCred = do
  let networkBit, payCredTypeBit :: Word64
      networkBit =
        case network of
          Mainnet -> 0 `setBit` 1
          Testnet -> 0
      payCredTypeBit =
        case paymentCred of
          KeyHashObj {} -> 0 `setBit` 0
          ScriptHashObj {} -> 0
      encodeAddr ::
        Hash (CC.ADDRHASH c) a ->
        Maybe (SizeHash (CC.ADDRHASH c) :~: 28, Addr28Extra)
      encodeAddr h = do
        refl@Refl <- sameNat (Proxy @(SizeHash (CC.ADDRHASH c))) (Proxy @28)
        case hashToPackedBytes h of
          PackedBytes28 a b c d ->
            let d' = (fromIntegral d `shiftL` 32) .|. networkBit .|. payCredTypeBit
             in Just (refl, Addr28Extra a b c d')
          _ -> Nothing
  case paymentCred of
    KeyHashObj (KeyHash addrHash) -> encodeAddr addrHash
    ScriptHashObj (ScriptHash addrHash) -> encodeAddr addrHash

encodeDataHash32 ::
  forall c.
  (HashAlgorithm (CC.HASH c)) =>
  DataHash c ->
  Maybe (SizeHash (CC.HASH c) :~: 32, DataHash32)
encodeDataHash32 dataHash = do
  refl@Refl <- sameNat (Proxy @(SizeHash (CC.HASH c))) (Proxy @32)
  case hashToPackedBytes (extractHash dataHash) of
    PackedBytes32 a b c d -> Just (refl, DataHash32 a b c d)
    _ -> Nothing

getAdaOnly ::
  forall era.
  Val (Value era) =>
  Proxy era ->
  Value era ->
  Maybe (CompactForm Coin)
getAdaOnly _ v = do
  guard $ isAdaOnly v
  toCompact $ coin v

pattern AlonzoTxOut ::
  forall era.
  (Era era, Val (Value era), HasCallStack) =>
  Addr (EraCrypto era) ->
  Value era ->
  StrictMaybe (DataHash (EraCrypto era)) ->
  AlonzoTxOut era
pattern AlonzoTxOut addr vl dh <-
  (viewTxOut -> (addr, vl, dh))
  where
    AlonzoTxOut (Addr network paymentCred stakeRef) vl SNothing
      | StakeRefBase stakeCred <- stakeRef,
        Just adaCompact <- getAdaOnly (Proxy @era) vl,
        Just (Refl, addr28Extra) <- encodeAddress28 network paymentCred =
        TxOut_AddrHash28_AdaOnly stakeCred addr28Extra adaCompact
    AlonzoTxOut (Addr network paymentCred stakeRef) vl (SJust dh)
      | StakeRefBase stakeCred <- stakeRef,
        Just adaCompact <- getAdaOnly (Proxy @era) vl,
        Just (Refl, addr28Extra) <- encodeAddress28 network paymentCred,
        Just (Refl, dataHash32) <- encodeDataHash32 dh =
        TxOut_AddrHash28_AdaOnly_DataHash32 stakeCred addr28Extra adaCompact dataHash32
    AlonzoTxOut addr vl mdh =
      let v = fromMaybe (error "Illegal value in txout") $ toCompact vl
          a = compactAddr addr
       in case mdh of
            SNothing -> TxOutCompact' a v
            SJust dh -> TxOutCompactDH' a v dh

{-# COMPLETE AlonzoTxOut #-}

instance (CC.Crypto c, AlonzoEraPParams (AlonzoEra c)) => EraTxOut (AlonzoEra c) where
  {-# SPECIALIZE instance AlonzoEraPParams (AlonzoEra CC.StandardCrypto) => EraTxOut (AlonzoEra CC.StandardCrypto) #-}

  type TxOut (AlonzoEra c) = AlonzoTxOut (AlonzoEra c)

  mkBasicTxOut addr vl = AlonzoTxOut addr vl SNothing

  addrEitherTxOutL =
    lens
      getAlonzoTxOutEitherAddr
      ( \txOut eAddr ->
          let cVal = getTxOutCompactValue txOut
              (_, _, dh) = viewTxOut txOut
           in case eAddr of
                Left addr -> mkTxOutCompact addr (compactAddr addr) cVal dh
                Right cAddr -> mkTxOutCompact (decompactAddr cAddr) cAddr cVal dh
      )
  {-# INLINE addrEitherTxOutL #-}

  valueEitherTxOutL =
    lens
      (Right . getTxOutCompactValue)
      ( \txOut eVal ->
          case eVal of
            Left val ->
              let (addr, _, dh) = viewTxOut txOut
               in AlonzoTxOut addr val dh
            Right cVal ->
              let dh = getAlonzoTxOutDataHash txOut
               in case getAlonzoTxOutEitherAddr txOut of
                    Left addr -> mkTxOutCompact addr (compactAddr addr) cVal dh
                    Right cAddr -> mkTxOutCompact (decompactAddr cAddr) cAddr cVal dh
      )
  {-# INLINE valueEitherTxOutL #-}

  getMinCoinTxOut pp txOut = Coin $ utxoEntrySize txOut * unCoin (pp ^. ppCoinsPerUTxOWordL)

instance
  (Era era, Val (Value era), DecodeNonNegative (Value era), ToCBOR (CompactForm (Value era))) =>
  ToCBOR (AlonzoTxOut era)
  where
  toCBOR (TxOutCompact addr cv) =
    encodeListLen 2
      <> toCBOR addr
      <> toCBOR cv
  toCBOR (TxOutCompactDH addr cv dh) =
    encodeListLen 3
      <> toCBOR addr
      <> toCBOR cv
      <> toCBOR dh

instance
  (Era era, Show (Value era), Val (Value era), DecodeNonNegative (Value era)) =>
  FromCBOR (AlonzoTxOut era)
  where
  fromCBOR = fromNotSharedCBOR
  {-# INLINE fromCBOR #-}

instance
  (Era era, Val (Value era), DecodeNonNegative (Value era), Show (Value era)) =>
  FromSharedCBOR (AlonzoTxOut era)
  where
  type Share (AlonzoTxOut era) = Interns (Credential 'Staking (EraCrypto era))
  fromSharedCBOR credsInterns = do
    lenOrIndef <- decodeListLenOrIndef
    let internTxOut = \case
          TxOut_AddrHash28_AdaOnly cred addr28Extra ada ->
            TxOut_AddrHash28_AdaOnly (interns credsInterns cred) addr28Extra ada
          TxOut_AddrHash28_AdaOnly_DataHash32 cred addr28Extra ada dataHash32 ->
            TxOut_AddrHash28_AdaOnly_DataHash32 (interns credsInterns cred) addr28Extra ada dataHash32
          txOut -> txOut
    internTxOut <$!> case lenOrIndef of
      Nothing -> do
        (a, ca) <- fromCborBackwardsBothAddr
        cv <- decodeNonNegative
        decodeBreakOr >>= \case
          True -> pure $ mkTxOutCompact a ca cv SNothing
          False -> do
            dh <- fromCBOR
            decodeBreakOr >>= \case
              True -> pure $ mkTxOutCompact a ca cv (SJust dh)
              False -> cborError $ DecoderErrorCustom "txout" "Excess terms in txout"
      Just 2 -> do
        (a, ca) <- fromCborBackwardsBothAddr
        cv <- decodeNonNegative
        pure $ mkTxOutCompact a ca cv SNothing
      Just 3 -> do
        (a, ca) <- fromCborBackwardsBothAddr
        cv <- decodeNonNegative
        mkTxOutCompact a ca cv . SJust <$> fromCBOR
      Just _ -> cborError $ DecoderErrorCustom "txout" "wrong number of terms in txout"
  {-# INLINEABLE fromSharedCBOR #-}

pattern TxOutCompact ::
  (Era era, Val (Value era), HasCallStack) =>
  CompactAddr (EraCrypto era) ->
  CompactForm (Value era) ->
  AlonzoTxOut era
pattern TxOutCompact addr vl <-
  (viewCompactTxOut -> (addr, vl, SNothing))
  where
    TxOutCompact cAddr cVal = mkTxOutCompact (decompactAddr cAddr) cAddr cVal SNothing

pattern TxOutCompactDH ::
  (Era era, Val (Value era), HasCallStack) =>
  CompactAddr (EraCrypto era) ->
  CompactForm (Value era) ->
  DataHash (EraCrypto era) ->
  AlonzoTxOut era
pattern TxOutCompactDH addr vl dh <-
  (viewCompactTxOut -> (addr, vl, SJust dh))
  where
    TxOutCompactDH cAddr cVal dh = mkTxOutCompact (decompactAddr cAddr) cAddr cVal (SJust dh)

{-# COMPLETE TxOutCompact, TxOutCompactDH #-}

mkTxOutCompact ::
  (Era era, HasCallStack, Val (Value era)) =>
  Addr (EraCrypto era) ->
  CompactAddr (EraCrypto era) ->
  CompactForm (Value era) ->
  StrictMaybe (DataHash (EraCrypto era)) ->
  AlonzoTxOut era
mkTxOutCompact addr cAddr cVal mdh
  | isAdaOnlyCompact cVal = AlonzoTxOut addr (fromCompact cVal) mdh
  | SJust dh <- mdh = TxOutCompactDH' cAddr cVal dh
  | otherwise = TxOutCompact' cAddr cVal

getAlonzoTxOutDataHash ::
  forall era.
  HashAlgorithm (CC.HASH (EraCrypto era)) =>
  AlonzoTxOut era ->
  StrictMaybe (DataHash (EraCrypto era))
getAlonzoTxOutDataHash = \case
  TxOutCompactDH' _ _ dh -> SJust dh
  TxOut_AddrHash28_AdaOnly_DataHash32 _ _ _ dh -> maybeToStrictMaybe $ decodeDataHash32 dh
  _ -> SNothing

getAlonzoTxOutEitherAddr ::
  HashAlgorithm (CC.ADDRHASH (EraCrypto era)) =>
  AlonzoTxOut era ->
  Either (Addr (EraCrypto era)) (CompactAddr (EraCrypto era))
getAlonzoTxOutEitherAddr = \case
  TxOutCompact' cAddr _ -> Right cAddr
  TxOutCompactDH' cAddr _ _ -> Right cAddr
  TxOut_AddrHash28_AdaOnly stakeRef addr28Extra _
    | Just addr <- decodeAddress28 stakeRef addr28Extra -> Left addr
    | otherwise -> error addressErrorMsg
  TxOut_AddrHash28_AdaOnly_DataHash32 stakeRef addr28Extra _ _
    | Just addr <- decodeAddress28 stakeRef addr28Extra -> Left addr
    | otherwise -> error addressErrorMsg

-- | Compute an estimate of the size of storing one UTxO entry.
-- This function implements the UTxO entry size estimate done by scaledMinDeposit in the ShelleyMA era
utxoEntrySize :: AlonzoEraTxOut era => Core.TxOut era -> Integer
utxoEntrySize txOut = utxoEntrySizeWithoutVal + size v + dataHashSize dh
  where
    v = txOut ^. valueTxOutL
    dh = txOut ^. dataHashTxOutL
    -- lengths obtained from tracing on HeapWords of inputs and outputs
    -- obtained experimentally, and number used here
    -- units are Word64s

    -- size of UTxO entry excluding the Value part
    utxoEntrySizeWithoutVal :: Integer
    utxoEntrySizeWithoutVal = 27 -- 6 + txoutLenNoVal [14] + txinLen [7]

class EraTxOut era => AlonzoEraTxOut era where
  dataHashTxOutL :: Lens' (Core.TxOut era) (StrictMaybe (DataHash (EraCrypto era)))

  datumTxOutF :: SimpleGetter (Core.TxOut era) (Datum era)

instance AlonzoEraPParams (AlonzoEra c) => AlonzoEraTxOut (AlonzoEra c) where
  {-# SPECIALIZE instance AlonzoEraPParams (AlonzoEra CC.StandardCrypto) => AlonzoEraTxOut (AlonzoEra CC.StandardCrypto) #-}

  dataHashTxOutL =
    lens getAlonzoTxOutDataHash (\(AlonzoTxOut addr cv _) dh -> AlonzoTxOut addr cv dh)
  {-# INLINEABLE dataHashTxOutL #-}

  datumTxOutF = to $ \txOut ->
    case getAlonzoTxOutDataHash txOut of
      SNothing -> NoDatum
      SJust dh -> DatumHash dh
  {-# INLINEABLE datumTxOutF #-}

getTxOutCompactValue :: EraTxOut era => AlonzoTxOut era -> CompactForm (Value era)
getTxOutCompactValue =
  \case
    TxOutCompact' _ cv -> cv
    TxOutCompactDH' _ cv _ -> cv
    TxOut_AddrHash28_AdaOnly _ _ cc -> injectCompact cc
    TxOut_AddrHash28_AdaOnly_DataHash32 _ _ cc _ -> injectCompact cc
