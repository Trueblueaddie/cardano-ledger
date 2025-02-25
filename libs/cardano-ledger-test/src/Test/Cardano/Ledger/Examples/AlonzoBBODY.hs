{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Test.Cardano.Ledger.Examples.AlonzoBBODY (tests) where

import Cardano.Crypto.Hash.Class (sizeHash)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Data (Data (..), hashData)
import Cardano.Ledger.Alonzo.Language (Language (..))
import Cardano.Ledger.Alonzo.Rules
  ( AlonzoBbodyPredFailure (..),
  )
import Cardano.Ledger.Alonzo.Scripts
  ( CostModels (..),
    ExUnits (..),
  )
import qualified Cardano.Ledger.Alonzo.Scripts as Tag (Tag (..))
import Cardano.Ledger.Alonzo.TxWits (RdmrPtr (..), Redeemers (..))
import Cardano.Ledger.BHeaderView (BHeaderView (..))
import Cardano.Ledger.BaseTypes
  ( BlocksMade (..),
    Network (..),
    StrictMaybe (..),
    textToUrl,
  )
import Cardano.Ledger.Block (Block (..), txid)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core hiding (TranslationError)
import Cardano.Ledger.Credential
  ( Credential (..),
    StakeCredential,
    StakeReference (..),
  )
import qualified Cardano.Ledger.Crypto as CC
import Cardano.Ledger.Keys
  ( KeyPair (..),
    KeyRole (..),
    coerceKeyRole,
    hashKey,
    hashVerKeyVRF,
  )
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Pretty.Babbage ()
import Cardano.Ledger.SafeHash (hashAnnotated)
import Cardano.Ledger.Shelley.API
  ( DPState (..),
    DState (..),
    LedgerState (..),
    PoolParams (..),
    ProtVer (..),
    UTxO (..),
  )
import Cardano.Ledger.Shelley.BlockChain (bBodySize)
import Cardano.Ledger.Shelley.LedgerState
  ( smartUTxOState,
  )
import Cardano.Ledger.Shelley.Rules
  ( ShelleyBbodyPredFailure (..),
    ShelleyBbodyState (..),
    ShelleyDelegsPredFailure (..),
    ShelleyDelplPredFailure (..),
    ShelleyLedgerPredFailure (..),
    ShelleyLedgersPredFailure (..),
    ShelleyPoolPredFailure (..),
  )
import Cardano.Ledger.Shelley.TxBody
  ( DCert (..),
    DelegCert (..),
    PoolCert (..),
    PoolMetadata (..),
    RewardAcnt (..),
    Wdrl (..),
  )
import Cardano.Ledger.Shelley.UTxO (makeWitnessVKey)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<+>))
import Cardano.Slotting.Slot (SlotNo (..))
import Control.State.Transition.Extended hiding (Assertion)
import qualified Data.ByteString as BS (replicate)
import Data.Default.Class (Default (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)
import qualified Data.Sequence.Strict as StrictSeq
import Data.UMap (View (Rewards))
import qualified Data.UMap as UM
import qualified PlutusLedgerApi.V1 as Plutus
import Test.Cardano.Ledger.Examples.STSTestUtils
  ( alwaysFailsHash,
    alwaysSucceedsHash,
    freeCostModelV1,
    initUTxO,
    mkGenesisTxIn,
    mkTxDats,
    someAddr,
    someKeys,
    someScriptAddr,
    testBBODY,
    trustMeP,
  )
import Test.Cardano.Ledger.Generic.Fields
  ( PParamsField (..),
    TxBodyField (..),
    TxField (..),
    TxOutField (..),
    WitnessesField (..),
  )
import Test.Cardano.Ledger.Generic.PrettyCore ()
import Test.Cardano.Ledger.Generic.Proof
import Test.Cardano.Ledger.Generic.Scriptic (HasTokens (..), PostShelley, Scriptic (..), after, matchkey)
import Test.Cardano.Ledger.Generic.Updaters
import Test.Cardano.Ledger.Shelley.Utils
  ( RawSeed (..),
    mkKeyPair,
    mkVRFKeyPair,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

tests :: TestTree
tests =
  testGroup
    "Generic Tests, testing Alonzo PredicateFailures, in postAlonzo eras."
    [ alonzoBBODYexamplesP (Alonzo Mock),
      alonzoBBODYexamplesP (Babbage Mock),
      alonzoBBODYexamplesP (Conway Mock)
    ]

alonzoBBODYexamplesP ::
  forall era.
  ( GoodCrypto (EraCrypto era),
    HasTokens era,
    Default (State (EraRule "PPUP" era)),
    PostShelley era,
    Value era ~ MaryValue (EraCrypto era),
    EraSegWits era
  ) =>
  Proof era ->
  TestTree
alonzoBBODYexamplesP proof =
  testGroup
    (show proof ++ " BBODY examples")
    [ testCase "eight plutus scripts cases" $
        testBBODY
          (BBODY proof)
          (initialBBodyState proof (initUTxO proof))
          (testAlonzoBlock proof)
          (Right (testBBodyState proof))
          (pp proof),
      testCase "block with bad pool md hash in tx" $
        testBBODY
          (BBODY proof)
          (initialBBodyState proof (initUTxO proof))
          (testAlonzoBadPMDHBlock proof)
          (Left [makeTooBig proof])
          (pp proof)
    ]

initialBBodyState ::
  ( Default (State (EraRule "PPUP" era)),
    EraTxOut era,
    PostShelley era
  ) =>
  Proof era ->
  UTxO era ->
  ShelleyBbodyState era
initialBBodyState pf utxo =
  BbodyState (LedgerState initialUtxoSt dpstate) (BlocksMade mempty)
  where
    initialUtxoSt = smartUTxOState utxo (Coin 0) (Coin 0) def
    dpstate =
      def
        { dpsDState =
            def {dsUnified = UM.insert (scriptStakeCredSuceed pf) (Coin 1000) (Rewards UM.empty)}
        }

testAlonzoBlock ::
  ( GoodCrypto (EraCrypto era),
    HasTokens era,
    Scriptic era,
    EraSegWits era,
    Value era ~ MaryValue (EraCrypto era)
  ) =>
  Proof era ->
  Block (BHeaderView (EraCrypto era)) era
testAlonzoBlock pf =
  makeNaiveBlock
    [ trustMeP pf True $ validatingTx pf,
      trustMeP pf False $ notValidatingTx pf,
      trustMeP pf True $ validatingTxWithWithdrawal pf,
      trustMeP pf False $ notValidatingTxWithWithdrawal pf,
      trustMeP pf True $ validatingTxWithCert pf,
      trustMeP pf False $ notValidatingTxWithCert pf,
      trustMeP pf True $ validatingTxWithMint pf,
      trustMeP pf False $ notValidatingTxWithMint pf
    ]

testAlonzoBadPMDHBlock :: GoodCrypto (EraCrypto era) => Proof era -> Block (BHeaderView (EraCrypto era)) era
testAlonzoBadPMDHBlock pf@(Alonzo _) = makeNaiveBlock [trustMeP pf True $ poolMDHTooBigTx pf]
testAlonzoBadPMDHBlock pf@(Babbage _) = makeNaiveBlock [trustMeP pf True $ poolMDHTooBigTx pf]
testAlonzoBadPMDHBlock pf@(Conway _) = makeNaiveBlock [trustMeP pf True $ poolMDHTooBigTx pf]
testAlonzoBadPMDHBlock other = error ("testAlonzoBadPMDHBlock does not work in era " ++ show other)

-- ============================== DATA ===============================

someDatum :: Era era => Data era
someDatum = Data (Plutus.I 123)

anotherDatum :: Era era => Data era
anotherDatum = Data (Plutus.I 0)

validatingTx ::
  forall era.
  ( Scriptic era,
    EraTx era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
validatingTx pf =
  newTx
    pf
    [ Body (validatingBody pf),
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated (validatingBody pf)) (someKeys pf)],
          ScriptWits' [always 3 pf],
          DataWits' [someDatum],
          RdmrWits validatingRedeemers
        ]
    ]

validatingBody :: (Scriptic era, EraTxBody era) => Proof era -> TxBody era
validatingBody pf =
  newTxBody
    pf
    [ Inputs' [mkGenesisTxIn 1],
      Collateral' [mkGenesisTxIn 11],
      Outputs' [validatingTxOut pf],
      Txfee (Coin 5),
      WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] validatingRedeemers (mkTxDats someDatum))
    ]

validatingRedeemers :: Era era => Redeemers era
validatingRedeemers =
  Redeemers $
    Map.singleton (RdmrPtr Tag.Spend 0) (Data (Plutus.I 42), ExUnits 5000 5000)

validatingTxOut :: EraTxOut era => Proof era -> TxOut era
validatingTxOut pf = newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 4995)]

notValidatingTx ::
  ( Scriptic era,
    EraTx era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
notValidatingTx pf =
  newTx
    pf
    [ Body notValidatingBody,
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated notValidatingBody) (someKeys pf)],
          ScriptWits' [never 0 pf],
          DataWits' [anotherDatum],
          RdmrWits notValidatingRedeemers
        ]
    ]
  where
    notValidatingBody =
      newTxBody
        pf
        [ Inputs' [mkGenesisTxIn 2],
          Collateral' [mkGenesisTxIn 12],
          Outputs' [newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 2995)]],
          Txfee (Coin 5),
          WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] notValidatingRedeemers (mkTxDats anotherDatum))
        ]
    notValidatingRedeemers =
      Redeemers
        ( Map.fromList
            [ ( RdmrPtr Tag.Spend 0,
                (Data (Plutus.I 1), ExUnits 5000 5000)
              )
            ]
        )

validatingTxWithWithdrawal ::
  forall era.
  ( Scriptic era,
    EraTx era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
validatingTxWithWithdrawal pf =
  newTx
    pf
    [ Body (validatingBodyWithWithdrawal pf),
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated (validatingBodyWithWithdrawal pf)) (someKeys pf)],
          ScriptWits' [always 2 pf],
          RdmrWits validatingWithWithdrawalRedeemers
        ]
    ]

validatingBodyWithWithdrawal :: (EraTxBody era, Scriptic era) => Proof era -> TxBody era
validatingBodyWithWithdrawal pf =
  newTxBody
    pf
    [ Inputs' [mkGenesisTxIn 5],
      Collateral' [mkGenesisTxIn 15],
      Outputs' [validatingTxWithWithdrawalOut pf],
      Txfee (Coin 5),
      Wdrls
        ( Wdrl $
            Map.singleton
              (RewardAcnt Testnet (scriptStakeCredSuceed pf))
              (Coin 1000)
        ),
      WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] validatingWithWithdrawalRedeemers mempty)
    ]

validatingWithWithdrawalRedeemers :: Era era => Redeemers era
validatingWithWithdrawalRedeemers =
  Redeemers $
    Map.singleton (RdmrPtr Tag.Rewrd 0) (Data (Plutus.I 42), ExUnits 5000 5000)

validatingTxWithWithdrawalOut :: EraTxOut era => Proof era -> TxOut era
validatingTxWithWithdrawalOut pf = newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 1995)]

notValidatingTxWithWithdrawal ::
  forall era.
  ( Scriptic era,
    EraTx era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
notValidatingTxWithWithdrawal pf =
  newTx
    pf
    [ Body notValidatingBodyWithWithdrawal,
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated notValidatingBodyWithWithdrawal) (someKeys pf)],
          ScriptWits' [never 1 pf],
          RdmrWits notValidatingRedeemers
        ]
    ]
  where
    notValidatingBodyWithWithdrawal =
      newTxBody
        pf
        [ Inputs' [mkGenesisTxIn 6],
          Collateral' [mkGenesisTxIn 16],
          Outputs' [newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 1995)]],
          Txfee (Coin 5),
          Wdrls
            ( Wdrl $
                Map.singleton
                  (RewardAcnt Testnet (scriptStakeCredFail pf))
                  (Coin 1000)
            ),
          WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] notValidatingRedeemers mempty)
        ]
    notValidatingRedeemers = Redeemers $ Map.singleton (RdmrPtr Tag.Rewrd 0) (Data (Plutus.I 0), ExUnits 5000 5000)

validatingTxWithCert ::
  forall era.
  ( Scriptic era,
    EraTx era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
validatingTxWithCert pf =
  newTx
    pf
    [ Body (validatingBodyWithCert pf),
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated (validatingBodyWithCert pf)) (someKeys pf)],
          ScriptWits' [always 2 pf],
          RdmrWits validatingRedeemrsWithCert
        ]
    ]

validatingBodyWithCert :: (Scriptic era, EraTxBody era) => Proof era -> TxBody era
validatingBodyWithCert pf =
  newTxBody
    pf
    [ Inputs' [mkGenesisTxIn 3],
      Collateral' [mkGenesisTxIn 13],
      Outputs' [validatingTxWithCertOut pf],
      Certs' [DCertDeleg (DeRegKey $ scriptStakeCredSuceed pf)],
      Txfee (Coin 5),
      WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] validatingRedeemrsWithCert mempty)
    ]

validatingRedeemrsWithCert :: Era era => Redeemers era
validatingRedeemrsWithCert =
  Redeemers $
    Map.singleton (RdmrPtr Tag.Cert 0) (Data (Plutus.I 42), ExUnits 5000 5000)

validatingTxWithCertOut :: EraTxOut era => Proof era -> TxOut era
validatingTxWithCertOut pf = newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 995)]

notValidatingTxWithCert ::
  forall era.
  ( Scriptic era,
    EraTx era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
notValidatingTxWithCert pf =
  newTx
    pf
    [ Body notValidatingBodyWithCert,
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated notValidatingBodyWithCert) (someKeys pf)],
          ScriptWits' [never 1 pf],
          RdmrWits notValidatingRedeemersWithCert
        ]
    ]
  where
    notValidatingBodyWithCert =
      newTxBody
        pf
        [ Inputs' [mkGenesisTxIn 4],
          Collateral' [mkGenesisTxIn 14],
          Outputs' [newTxOut pf [Address (someAddr pf), Amount (inject $ Coin 995)]],
          Certs' [DCertDeleg (DeRegKey $ scriptStakeCredFail pf)],
          Txfee (Coin 5),
          WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] notValidatingRedeemersWithCert mempty)
        ]
    notValidatingRedeemersWithCert = Redeemers $ Map.singleton (RdmrPtr Tag.Cert 0) (Data (Plutus.I 0), ExUnits 5000 5000)

validatingTxWithMint ::
  forall era.
  ( Scriptic era,
    HasTokens era,
    EraTx era,
    GoodCrypto (EraCrypto era),
    Value era ~ MaryValue (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
validatingTxWithMint pf =
  newTx
    pf
    [ Body (validatingBodyWithMint pf),
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated (validatingBodyWithMint pf)) (someKeys pf)],
          ScriptWits' [always 2 pf],
          RdmrWits validatingRedeemersWithMint
        ]
    ]

validatingBodyWithMint ::
  (HasTokens era, EraTxBody era, Scriptic era, Value era ~ MaryValue (EraCrypto era)) =>
  Proof era ->
  TxBody era
validatingBodyWithMint pf =
  newTxBody
    pf
    [ Inputs' [mkGenesisTxIn 7],
      Collateral' [mkGenesisTxIn 17],
      Outputs' [validatingTxWithMintOut pf],
      Txfee (Coin 5),
      Mint (multiAsset pf),
      WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] validatingRedeemersWithMint mempty)
    ]

validatingRedeemersWithMint :: Era era => Redeemers era
validatingRedeemersWithMint =
  Redeemers $
    Map.singleton (RdmrPtr Tag.Mint 0) (Data (Plutus.I 42), ExUnits 5000 5000)

multiAsset :: forall era. (Scriptic era, HasTokens era) => Proof era -> MultiAsset (EraCrypto era)
multiAsset pf = forge @era 1 (always 2 pf)

validatingTxWithMintOut :: forall era. (HasTokens era, EraTxOut era, Scriptic era, Value era ~ MaryValue (EraCrypto era)) => Proof era -> TxOut era
validatingTxWithMintOut pf = newTxOut pf [Address (someAddr pf), Amount (MaryValue 0 (multiAsset pf) <+> inject (Coin 995))]

notValidatingTxWithMint ::
  forall era.
  ( Scriptic era,
    HasTokens era,
    EraTx era,
    GoodCrypto (EraCrypto era),
    Value era ~ MaryValue (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
notValidatingTxWithMint pf =
  newTx
    pf
    [ Body notValidatingBodyWithMint,
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated notValidatingBodyWithMint) (someKeys pf)],
          ScriptWits' [never 1 pf],
          RdmrWits notValidatingRedeemersWithMint
        ]
    ]
  where
    notValidatingBodyWithMint =
      newTxBody
        pf
        [ Inputs' [mkGenesisTxIn 8],
          Collateral' [mkGenesisTxIn 18],
          Outputs' [newTxOut pf [Address (someAddr pf), Amount (MaryValue 0 ma <+> inject (Coin 995))]],
          Txfee (Coin 5),
          Mint ma,
          WppHash (newScriptIntegrityHash pf (pp pf) [PlutusV1] notValidatingRedeemersWithMint mempty)
        ]
    notValidatingRedeemersWithMint = Redeemers $ Map.singleton (RdmrPtr Tag.Mint 0) (Data (Plutus.I 0), ExUnits 5000 5000)
    ma = forge @era 1 (never 1 pf)

poolMDHTooBigTx ::
  forall era.
  ( Scriptic era,
    EraTxBody era,
    GoodCrypto (EraCrypto era)
  ) =>
  Proof era ->
  Tx era
poolMDHTooBigTx pf =
  -- Note that the UTXOW rule will no trigger the expected predicate failure,
  -- since it is checked in the POOL rule. BBODY will trigger it, however.
  newTx
    pf
    [ Body poolMDHTooBigTxBody,
      WitnessesI
        [ AddrWits' [makeWitnessVKey (hashAnnotated poolMDHTooBigTxBody) (someKeys pf)]
        ]
    ]
  where
    poolMDHTooBigTxBody =
      newTxBody
        pf
        [ Inputs' [mkGenesisTxIn 3],
          Outputs' [newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 995)]],
          Certs' [DCertPool (RegPool poolParams)],
          Txfee (Coin 5)
        ]
      where
        tooManyBytes = BS.replicate (hashsize @(EraCrypto era) + 1) 0
        poolParams =
          PoolParams
            { _poolId = coerceKeyRole . hashKey . vKey $ someKeys pf,
              _poolVrf = hashVerKeyVRF . snd . mkVRFKeyPair $ RawSeed 0 0 0 0 0,
              _poolPledge = Coin 0,
              _poolCost = Coin 0,
              _poolMargin = minBound,
              _poolRAcnt = RewardAcnt Testnet (scriptStakeCredSuceed pf),
              _poolOwners = mempty,
              _poolRelays = mempty,
              _poolMD = SJust $ PoolMetadata (fromJust $ textToUrl "") tooManyBytes
            }

-- ============================== Expected UTXO  ===============================

testBBodyState ::
  forall era.
  ( GoodCrypto (EraCrypto era),
    HasTokens era,
    PostShelley era,
    Default (State (EraRule "PPUP" era)),
    EraTxBody era,
    Value era ~ MaryValue (EraCrypto era)
  ) =>
  Proof era ->
  ShelleyBbodyState era
testBBodyState pf =
  let utxo =
        UTxO $
          Map.fromList
            [ (TxIn (txid (validatingBody pf)) minBound, validatingTxOut pf),
              (TxIn (txid (validatingBodyWithCert pf)) minBound, validatingTxWithCertOut pf),
              (TxIn (txid (validatingBodyWithWithdrawal pf)) minBound, validatingTxWithWithdrawalOut pf),
              (TxIn (txid (validatingBodyWithMint pf)) minBound, validatingTxWithMintOut pf),
              (mkGenesisTxIn 11, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 5)]),
              (mkGenesisTxIn 2, alwaysFailsOutput),
              (mkGenesisTxIn 13, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 5)]),
              (mkGenesisTxIn 4, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 1000)]),
              (mkGenesisTxIn 15, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 5)]),
              (mkGenesisTxIn 6, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 1000)]),
              (mkGenesisTxIn 17, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 5)]),
              (mkGenesisTxIn 8, newTxOut pf [Address $ someAddr pf, Amount (inject $ Coin 1000)]),
              (mkGenesisTxIn 100, timelockOut),
              (mkGenesisTxIn 101, unspendableOut),
              (mkGenesisTxIn 102, alwaysSucceedsOutputV2),
              (mkGenesisTxIn 103, nonScriptOutWithDatum)
            ]
      alwaysFailsOutput =
        newTxOut
          pf
          [ Address (someScriptAddr (never 0 pf) pf),
            Amount (inject $ Coin 3000),
            DHash' [hashData $ anotherDatum @era]
          ]
      timelockOut = newTxOut pf [Address $ timelockAddr, Amount (inject $ Coin 1)]
      timelockAddr = Addr Testnet pCred sCred
        where
          (_ssk, svk) = mkKeyPair @(EraCrypto era) (RawSeed 0 0 0 0 2)
          pCred = ScriptHashObj timelockHash
          sCred = StakeRefBase . KeyHashObj . hashKey $ svk
          timelockHash = hashScript @era $ allOf [matchkey 1, after 100] pf
      -- This output is unspendable since it is locked by a plutus script,
      -- but has no datum hash.
      unspendableOut =
        newTxOut
          pf
          [ Address (someScriptAddr (always 3 pf) pf),
            Amount (inject $ Coin 5000)
          ]
      alwaysSucceedsOutputV2 =
        newTxOut
          pf
          [ Address (someScriptAddr (alwaysAlt 3 pf) pf),
            Amount (inject $ Coin 5000),
            DHash' [hashData $ someDatum @era]
          ]
      nonScriptOutWithDatum =
        newTxOut
          pf
          [ Address (someAddr pf),
            Amount (inject $ Coin 1221),
            DHash' [hashData $ someDatum @era]
          ]
      poolID = hashKey . vKey . coerceKeyRole $ coldKeys
      example1UtxoSt = smartUTxOState utxo (Coin 0) (Coin 40) def
   in BbodyState (LedgerState example1UtxoSt def) (BlocksMade $ Map.singleton poolID 1)

-- ============================== Helper functions ===============================

makeTooBig :: Proof era -> AlonzoBbodyPredFailure era
makeTooBig proof@(Alonzo _) =
  ShelleyInAlonzoBbodyPredFailure . LedgersFailure . LedgerFailure . DelegsFailure . DelplFailure . PoolFailure $
    PoolMedataHashTooBig (coerceKeyRole . hashKey . vKey $ someKeys proof) (hashsize @Mock + 1)
makeTooBig proof@(Babbage _) =
  ShelleyInAlonzoBbodyPredFailure . LedgersFailure . LedgerFailure . DelegsFailure . DelplFailure . PoolFailure $
    PoolMedataHashTooBig (coerceKeyRole . hashKey . vKey $ someKeys proof) (hashsize @Mock + 1)
makeTooBig proof@(Conway _) =
  ShelleyInAlonzoBbodyPredFailure . LedgersFailure . LedgerFailure . DelegsFailure . DelplFailure . PoolFailure $
    PoolMedataHashTooBig (coerceKeyRole . hashKey . vKey $ someKeys proof) (hashsize @Mock + 1)
makeTooBig proof = error ("makeTooBig does not work in era " ++ show proof)

coldKeys :: CC.Crypto c => KeyPair 'BlockIssuer c
coldKeys = KeyPair vk sk
  where
    (sk, vk) = mkKeyPair (RawSeed 1 2 3 2 1)

makeNaiveBlock ::
  forall era. EraSegWits era => [Tx era] -> Block (BHeaderView (EraCrypto era)) era
makeNaiveBlock txs = UnsafeUnserialisedBlock bhView txs'
  where
    bhView =
      BHeaderView
        { bhviewID = hashKey (vKey coldKeys),
          bhviewBSize = fromIntegral $ bBodySize txs',
          bhviewHSize = 0,
          bhviewBHash = hashTxSeq @era txs',
          bhviewSlot = SlotNo 0
        }
    txs' = (toTxSeq @era) . StrictSeq.fromList $ txs

scriptStakeCredFail :: forall era. Scriptic era => Proof era -> StakeCredential (EraCrypto era)
scriptStakeCredFail pf = ScriptHashObj (alwaysFailsHash 1 pf)

scriptStakeCredSuceed :: forall era. Scriptic era => Proof era -> StakeCredential (EraCrypto era)
scriptStakeCredSuceed pf = ScriptHashObj (alwaysSucceedsHash 2 pf)

hashsize :: forall c. CC.Crypto c => Int
hashsize = fromIntegral $ sizeHash ([] @(CC.HASH c))

-- ============================== PParams ===============================

defaultPPs :: [PParamsField era]
defaultPPs =
  [ Costmdls . CostModels $ Map.singleton PlutusV1 freeCostModelV1,
    MaxValSize 1000000000,
    MaxTxExUnits $ ExUnits 1000000 1000000,
    MaxBlockExUnits $ ExUnits 1000000 1000000,
    ProtocolVersion $ ProtVer 5 0,
    CollateralPercentage 100
  ]

pp :: Proof era -> PParams era
pp pf = newPParams pf defaultPPs
