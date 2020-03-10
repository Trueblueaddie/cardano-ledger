{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module Test.Shelley.Spec.Ledger.Examples.UnitTests (unitTests) where

import           Control.Monad (foldM)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Sequence (Seq (..))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import           Lens.Micro ((&), (.~), (^.))

import           Test.Tasty
import           Test.Tasty.HUnit

import           Shelley.Spec.Ledger.Address
import           Shelley.Spec.Ledger.BaseTypes
import           Shelley.Spec.Ledger.Coin
import           Shelley.Spec.Ledger.Delegation.Certificates (pattern Delegate, pattern RegKey,
                     pattern RegPool, pattern RetirePool, StakeCreds (..), StakePools (..))
import           Shelley.Spec.Ledger.TxData (pattern AddrBase, Credential (..), pattern DCertDeleg,
                     pattern DCertPool, Delegation (..), pattern PoolParams, pattern Ptr,
                     pattern RewardAcnt, Wdrl (..), _poolCost, _poolMD, _poolMargin, _poolOwners,
                     _poolPledge, _poolPubKey, _poolRAcnt, _poolRelays, _poolVrf)
import           Shelley.Spec.Ledger.Validation (ValidationError (..))

import           Shelley.Spec.Ledger.Keys (pattern KeyPair, hashKey, vKey)
import           Shelley.Spec.Ledger.LedgerState (pattern LedgerState, pattern UTxOState,
                     delegationState, delegations, dstate, emptyDelegation, genesisCoins,
                     genesisId, genesisState, minfee, overlaySchedule, pParams, pstate, ptrs,
                     retiring, rewards, stPools, stkCreds)
import           Shelley.Spec.Ledger.PParams
import           Shelley.Spec.Ledger.Slot
import           Shelley.Spec.Ledger.Tx (pattern Tx, pattern TxBody, pattern TxIn, pattern TxOut,
                     body, ttl)
import           Shelley.Spec.Ledger.Updates
import           Shelley.Spec.Ledger.UTxO (pattern UTxO, makeWitnessVKey, makeWitnessesVKey, txid)

import qualified Test.Cardano.Crypto.VRF.Fake as FakeVRF
import           Test.Shelley.Spec.Ledger.ConcreteCryptoTypes
import           Test.Shelley.Spec.Ledger.PreSTSGenerator (asStateTransition)
import           Test.Shelley.Spec.Ledger.Utils


alicePay :: KeyPair
alicePay = KeyPair 1 1

aliceStake :: KeyPair
aliceStake = KeyPair 2 2

aliceAddr :: Addr
aliceAddr = AddrBase
             (KeyHashObj . hashKey $ vKey alicePay)
             (KeyHashObj . hashKey $ vKey aliceStake)

bobPay :: KeyPair
bobPay = KeyPair 3 3

bobStake :: KeyPair
bobStake = KeyPair 4 4

bobAddr :: Addr
bobAddr = AddrBase
           (KeyHashObj . hashKey $ vKey bobPay)
           (KeyHashObj . hashKey $ vKey bobStake)

testPCs :: PParams
testPCs = emptyPParams {
    _minfeeA = 1
  , _minfeeB = 1
  , _keyDeposit = 100
  , _poolDeposit = 250
  , _maxTxSize = 1024
  , _eMax = EpochNo 10 }

aliceInitCoin :: Coin
aliceInitCoin = Coin 10000

bobInitCoin :: Coin
bobInitCoin = Coin 1000

genesis :: LedgerState
genesis = (genesisState Map.empty . genesisCoins)
            [ TxOut aliceAddr aliceInitCoin
            , TxOut bobAddr bobInitCoin ]

changeReward :: LedgerState -> RewardAcnt -> Coin -> LedgerState
changeReward ls acnt c = ls & delegationState . dstate . rewards .~ newAccounts
  where newAccounts = Map.insert acnt c (ls ^. delegationState . dstate. rewards)

stakePoolKey1 :: KeyPair
stakePoolKey1 = KeyPair 5 5

stakePoolVRFKey1 :: VerKeyVRF
stakePoolVRFKey1 = FakeVRF.VerKeyFakeVRF 15


ledgerState :: [Tx] -> Either [ValidationError] LedgerState
ledgerState = foldM (\l t -> asStateTransition (SlotNo 0) testPCs l t (Coin 0)) genesis

testLedgerValidTransactions ::
  Either [ValidationError] LedgerState -> UTxOState -> Assertion
testLedgerValidTransactions ls utxoState' =
    ls @?= Right (LedgerState
                     utxoState'
                     emptyDelegation
                     )

testValidStakeKeyRegistration ::
  Tx -> UTxOState -> DPState -> Assertion
testValidStakeKeyRegistration tx utxoState' stakeKeyRegistration =
  let
    ls2 = ledgerState [tx]
  in ls2 @?= Right (LedgerState
                     utxoState'
                     stakeKeyRegistration
                     )

testValidDelegation ::
  [Tx] -> UTxOState -> DPState -> PoolParams -> Assertion
testValidDelegation txs utxoState' stakeKeyRegistration pool =
  let
    ls2 = ledgerState txs
    poolhk = hashKey $ vKey stakePoolKey1
  in ls2 @?= Right
         (LedgerState
          utxoState'
          (stakeKeyRegistration
           & dstate . delegations .~
                Map.fromList [(KeyHashObj $ hashKey $ vKey aliceStake, poolhk)]
           & pstate . stPools .~ (StakePools $ Map.fromList [(poolhk, SlotNo 0)])
           & pstate . pParams .~ Map.fromList [(poolhk, pool)])
          )

testValidRetirement ::
  [Tx] -> UTxOState -> DPState -> EpochNo -> PoolParams -> Assertion
testValidRetirement txs utxoState' stakeKeyRegistration e pool =
  let
    ls2 = ledgerState txs
    poolhk = hashKey $ vKey stakePoolKey1
  in ls2 @?= Right
         (LedgerState
          utxoState'
          (stakeKeyRegistration
           & dstate . delegations .~
                Map.fromList [(KeyHashObj $ hashKey $ vKey aliceStake, poolhk)]
           & pstate . stPools .~  (StakePools $ Map.fromList [(poolhk, SlotNo 0)])
           & pstate . pParams .~ Map.fromList [(poolhk, pool)]
           & pstate . retiring .~ Map.fromList [(poolhk, e)])
          )

bobWithdrawal :: Map RewardAcnt Coin
bobWithdrawal = Map.singleton (mkVKeyRwdAcnt bobStake) (Coin 10)

genesisWithReward :: LedgerState
genesisWithReward = changeReward genesis (mkVKeyRwdAcnt bobStake) (Coin 10)

testValidWithdrawal :: Assertion
testValidWithdrawal =
  let
    tx = TxBody
           (Set.fromList [TxIn genesisId 0])
           (Seq.fromList [ TxOut aliceAddr (Coin 6000)
                         , TxOut bobAddr (Coin 3010) ])
           Empty
           (Wdrl bobWithdrawal)
           (Coin 1000)
           (SlotNo 0)
           emptyUpdate
           Nothing
    wits = makeWitnessesVKey tx [alicePay, bobStake]
    utxo' = Map.fromList
       [ (TxIn genesisId 1, TxOut bobAddr (Coin 1000))
       , (TxIn (txid tx) 0, TxOut aliceAddr (Coin 6000))
       , (TxIn (txid tx) 1, TxOut bobAddr (Coin 3010)) ]
    ls = asStateTransition
           (SlotNo 0) testPCs genesisWithReward (Tx tx wits Map.empty Nothing) (Coin 0)
    expectedDS = emptyDelegation & dstate . rewards .~
                   Map.singleton (mkVKeyRwdAcnt bobStake) (Coin 0)
  in ls @?= Right (LedgerState
                     (UTxOState (UTxO utxo') (Coin 0) (Coin 1000) emptyUpdateState)
                     expectedDS
                     )

testInvalidWintess :: Assertion
testInvalidWintess =
  let
    tx = TxBody
           (Set.fromList [TxIn genesisId 0])
           (Seq.fromList
              [ TxOut aliceAddr (Coin 6000)
              , TxOut bobAddr (Coin 3000) ])
           Empty
           (Wdrl Map.empty)
           (Coin 1000)
           (SlotNo 1)
           emptyUpdate
           Nothing
    tx' = tx & ttl .~ SlotNo 2
    wits = makeWitnessesVKey tx' [alicePay]
  in ledgerState [Tx tx wits Map.empty Nothing] @?= Left [InvalidWitness]

testWithdrawalNoWit :: Assertion
testWithdrawalNoWit =
  let
    tx = TxBody
           (Set.fromList [TxIn genesisId 0])
           (Seq.fromList
             [ TxOut aliceAddr (Coin 6000)
             , TxOut bobAddr (Coin 3010) ])
           Empty
           (Wdrl bobWithdrawal)
           (Coin 1000)
           (SlotNo 0)
           emptyUpdate
           Nothing
    wits = Set.singleton $ makeWitnessVKey tx alicePay
    ls = asStateTransition
      (SlotNo 0) testPCs genesisWithReward (Tx tx wits Map.empty Nothing) (Coin 0)
  in ls @?= Left [MissingWitnesses]

testWithdrawalWrongAmt :: Assertion
testWithdrawalWrongAmt =
  let
    tx = TxBody
           (Set.fromList [TxIn genesisId 0])
           (Seq.fromList
             [ TxOut aliceAddr (Coin 6000)
             , TxOut bobAddr (Coin 3011) ])
           Empty
           (Wdrl $ Map.singleton (mkVKeyRwdAcnt bobStake) (Coin 11))
           (Coin 1000)
           (SlotNo 0)
           emptyUpdate
           Nothing
    wits = makeWitnessesVKey tx [alicePay, bobStake]
    ls =asStateTransition
          (SlotNo 0) testPCs genesisWithReward (Tx tx wits Map.empty Nothing) (Coin 0)
  in ls @?= Left [IncorrectRewards]

aliceGivesBobLovelace :: TxIn -> Coin -> Coin -> Coin -> Coin ->
  [DCert] -> SlotNo -> [KeyPair] -> Tx
aliceGivesBobLovelace txin coin fee txdeps txrefs cs s signers = Tx txbody wits Map.empty Nothing
  where
    aliceCoin = aliceInitCoin + txrefs - (coin + fee + txdeps)
    txbody = TxBody
               (Set.fromList [txin])
               (Seq.fromList
                 [ TxOut aliceAddr aliceCoin
                 , TxOut bobAddr coin ])
               (Seq.fromList cs)
               (Wdrl Map.empty)
               fee
               s
               emptyUpdate
               Nothing
    wits = makeWitnessesVKey txbody signers

tx1 :: Tx
tx1 = aliceGivesBobLovelace
        (TxIn genesisId 0)
        (Coin 3000) (Coin 600) (Coin 0) (Coin 0)
        []
        (SlotNo 0)
        [alicePay]


utxoSt1 :: UTxOState
utxoSt1 = UTxOState
            (UTxO $ Map.fromList
               [ (TxIn genesisId 1, TxOut bobAddr (Coin 1000))
               , (TxIn (txid $ tx1 ^. body) 0, TxOut aliceAddr (Coin 6400))
               , (TxIn (txid $ tx1 ^. body) 1, TxOut bobAddr (Coin 3000)) ])
            (Coin 0)
            (Coin 600)
            emptyUpdateState

ls1 :: Either [ValidationError] LedgerState
ls1 = ledgerState [tx1]

tx2 :: Tx
tx2 = aliceGivesBobLovelace
        (TxIn genesisId 0)
        (Coin 3000) (Coin 1300) (Coin 3*100) (Coin 0)
        [ DCertDeleg (RegKey $ (KeyHashObj . hashKey) $ vKey aliceStake)
        , DCertDeleg (RegKey $ (KeyHashObj . hashKey) $ vKey bobStake)
        , DCertDeleg (RegKey $ (KeyHashObj . hashKey) $ vKey stakePoolKey1)]
        (SlotNo 100)
        [alicePay, aliceStake, bobStake, stakePoolKey1]


utxoSt2 :: UTxOState
utxoSt2 = UTxOState
            (UTxO $ Map.fromList
              [ (TxIn genesisId 1, TxOut bobAddr (Coin 1000))
              , (TxIn (txid $ tx2 ^. body) 0, TxOut aliceAddr (Coin 5400))
              , (TxIn (txid $ tx2 ^. body) 1, TxOut bobAddr (Coin 3000)) ])
            (Coin 300)
            (Coin 1300)
            emptyUpdateState

tx3Body :: TxBody
tx3Body = TxBody
          (Set.fromList [TxIn (txid $ tx2 ^. body) 0])
          (Seq.singleton $ TxOut aliceAddr (Coin 3950))
          (Seq.fromList [ DCertPool (RegPool stakePool)
                        , DCertDeleg (Delegate (Delegation
                                            (KeyHashObj $ hashKey $ vKey aliceStake)
                                            (hashKey $ vKey stakePoolKey1)))])
          (Wdrl Map.empty)
          (Coin 1200)
          (SlotNo 100)
          emptyUpdate
          Nothing

tx3 :: Tx
tx3 = Tx tx3Body (makeWitnessesVKey tx3Body keys) Map.empty Nothing
      where keys = [alicePay, aliceStake, stakePoolKey1]

utxoSt3 :: UTxOState
utxoSt3 = UTxOState
            (UTxO $ Map.fromList
              [ (TxIn genesisId 1, TxOut bobAddr (Coin 1000))
              , (TxIn (txid tx3Body) 0, TxOut aliceAddr (Coin 3950))
              , (TxIn (txid $ tx2 ^. body) 1, TxOut bobAddr (Coin 3000)) ])
            (Coin 550)
            (Coin 2500)
            emptyUpdateState

stakeKeyRegistration1 :: DPState
stakeKeyRegistration1 = emptyDelegation
  & dstate . rewards .~
      Map.fromList [ (mkVKeyRwdAcnt aliceStake, Coin 0)
                   , (mkVKeyRwdAcnt bobStake, Coin 0)
                   , (mkVKeyRwdAcnt stakePoolKey1, Coin 0)]
  & dstate . stkCreds .~ (StakeCreds $
      Map.fromList [ (KeyHashObj $ hashKey $ vKey aliceStake, SlotNo 0)
                   , (KeyHashObj $ hashKey $ vKey bobStake, SlotNo 0)
                   , (KeyHashObj $ hashKey $ vKey stakePoolKey1, SlotNo 0)])
  & dstate . ptrs .~
      Map.fromList [ (Ptr (SlotNo 0) 0 0, KeyHashObj $ hashKey $ vKey aliceStake)
                   , (Ptr (SlotNo 0) 0 1, KeyHashObj $ hashKey $ vKey bobStake)
                   , (Ptr (SlotNo 0) 0 2, KeyHashObj $ hashKey $ vKey stakePoolKey1)
                   ]

stakePool :: PoolParams
stakePool = PoolParams
            {
              _poolPubKey  = hashKey $ vKey stakePoolKey1
            , _poolVrf     = hashKeyVRF stakePoolVRFKey1
            , _poolPledge  = Coin 0
            , _poolCost    = Coin 0      -- TODO: what is a sensible value?
            , _poolMargin  = interval0     --          or here?
            , _poolRAcnt   = RewardAcnt (KeyHashObj . hashKey . vKey $ stakePoolKey1)
            , _poolOwners  = Set.empty
            , _poolRelays  = Seq.empty
            , _poolMD      = Nothing
            }

halfInterval :: UnitInterval
halfInterval =
    fromMaybe (error "could not construct unit interval") $ mkUnitInterval 0.5

stakePoolUpdate :: PoolParams
stakePoolUpdate = PoolParams
                   {
                     _poolPubKey  = hashKey $ vKey stakePoolKey1
                   , _poolVrf     = hashKeyVRF stakePoolVRFKey1
                   , _poolPledge  = Coin 0
                   , _poolCost    = Coin 100      -- TODO: what is a sensible value?
                   , _poolMargin  = halfInterval     --          or here?
                   , _poolRAcnt   = RewardAcnt (KeyHashObj . hashKey . vKey $ stakePoolKey1)
                   , _poolOwners  = Set.empty
                   , _poolRelays  = Seq.empty
                   , _poolMD      = Nothing
                   }

tx4Body :: TxBody
tx4Body = TxBody
          (Set.fromList [TxIn (txid $ tx3 ^. body) 0])
          (Seq.singleton $ TxOut aliceAddr (Coin 2950)) -- Note the deposit is not charged
          (Seq.fromList [ DCertPool (RegPool stakePoolUpdate) ])
          (Wdrl Map.empty)
          (Coin 1000)
          (SlotNo 100)
          emptyUpdate
          Nothing

tx4 :: Tx
tx4 = Tx tx4Body (makeWitnessesVKey tx4Body [alicePay, stakePoolKey1]) Map.empty Nothing

utxoSt4 :: UTxOState
utxoSt4 = UTxOState
            (UTxO $ Map.fromList
              [ (TxIn genesisId 1, TxOut bobAddr (Coin 1000))
              , (TxIn (txid tx4Body) 0, TxOut aliceAddr (Coin 2950))
              , (TxIn (txid $ tx2 ^. body) 1, TxOut bobAddr (Coin 3000)) ])
            (Coin 550)
            (Coin 3500)
            emptyUpdateState

utxo5 :: EpochNo -> UTxOState
utxo5 e = UTxOState
            (UTxO $ Map.fromList
              [ (TxIn genesisId 1, TxOut bobAddr (Coin 1000))
              , (TxIn (txid $ tx5Body e) 0, TxOut aliceAddr (Coin 2950))
              , (TxIn (txid $ tx2 ^. body) 1, TxOut bobAddr (Coin 3000)) ])
            (Coin 550)
            (Coin 3500)
            emptyUpdateState

tx5Body :: EpochNo -> TxBody
tx5Body e = TxBody
          (Set.fromList [TxIn (txid $ tx3 ^. body) 0])
          (Seq.singleton $ TxOut aliceAddr (Coin 2950))
          (Seq.fromList [ DCertPool (RetirePool (hashKey $ vKey stakePoolKey1) e) ])
          (Wdrl Map.empty)
          (Coin 1000)
          (SlotNo 100)
          emptyUpdate
          Nothing

tx5 :: EpochNo -> Tx
tx5 e = Tx (tx5Body e) (makeWitnessesVKey (tx5Body e) [alicePay, stakePoolKey1]) Map.empty Nothing


testsValidLedger :: TestTree
testsValidLedger =
  testGroup "Tests with valid transactions in ledger."
    [ testCase "Valid Ledger - Alice gives Bob 3000 of her 10000 lovelace" $
        testLedgerValidTransactions ls1 utxoSt1
      , testGroup "Tests for stake delegation."
          [ testCase "Valid stake key registration." $
              testValidStakeKeyRegistration tx2 utxoSt2 stakeKeyRegistration1
          , testCase "Valid stake delegation from Alice to stake pool." $
              testValidDelegation [tx2, tx3] utxoSt3 stakeKeyRegistration1 stakePool
          , testCase "Update stake pool parameters" $
              testValidDelegation [tx2, tx3, tx4] utxoSt4 stakeKeyRegistration1 stakePoolUpdate
          , testCase "Retire Pool" $
            testValidRetirement [tx2, tx3, tx5 (EpochNo 1)] (utxo5 (EpochNo 1)) stakeKeyRegistration1 (EpochNo 1) stakePool
          ]
      , testGroup "Tests for withdrawals"
          [ testCase "Valid withdrawal." testValidWithdrawal
          ]
    ]

testOverlayScheduleDZero :: Assertion
testOverlayScheduleDZero =
  let
    os = runShelleyBase
      $ overlaySchedule
        (EpochNo 0)
        mempty
        (emptyPParams {_d = unsafeMkUnitInterval 0})
  in os @?= Map.empty


testsDParam :: TestTree
testsDParam =
  testGroup "Test the d parameter."
    [ testCase "Overlay Schedule when d is zero" $
        testOverlayScheduleDZero
    ]

testSpendNonexistentInput :: Assertion
testSpendNonexistentInput =
  let
    tx = aliceGivesBobLovelace
           (TxIn genesisId 42)
           (Coin 3000) (Coin 1500) (Coin 0) (Coin 0)
           []
           (SlotNo 100)
           [alicePay]
  in ledgerState [tx] @?=
       Left [ ValueNotConserved (Coin 0) (Coin 10000)
            , BadInputs]

testWitnessNotIncluded :: Assertion
testWitnessNotIncluded =
  let
    txbody = TxBody
              (Set.fromList [TxIn genesisId 0])
              (Seq.fromList
                [ TxOut aliceAddr (Coin 6404)
                , TxOut bobAddr (Coin 3000) ])
              Empty
              (Wdrl Map.empty)
              (Coin 596)
              (SlotNo 100)
              emptyUpdate
              Nothing
    tx = Tx txbody Set.empty Map.empty Nothing
  in ledgerState [tx] @?= Left [MissingWitnesses]

testSpendNotOwnedUTxO :: Assertion
testSpendNotOwnedUTxO =
  let
    txbody = TxBody
              (Set.fromList [TxIn genesisId 1])
              (Seq.singleton $ TxOut aliceAddr (Coin 232))
              Empty
              (Wdrl Map.empty)
              (Coin 768)
              (SlotNo 100)
              emptyUpdate
              Nothing
    aliceWit = makeWitnessVKey txbody alicePay
    tx = Tx txbody (Set.fromList [aliceWit]) Map.empty Nothing
  in ledgerState [tx] @?= Left [MissingWitnesses]

testWitnessWrongUTxO :: Assertion
testWitnessWrongUTxO =
  let
    txbody = TxBody
              (Set.fromList [TxIn genesisId 1])
              (Seq.singleton $ TxOut aliceAddr (Coin 230))
              Empty
              (Wdrl Map.empty)
              (Coin 770)
              (SlotNo 100)
              emptyUpdate
              Nothing
    tx2body = TxBody
              (Set.fromList [TxIn genesisId 1])
              (Seq.singleton $ TxOut aliceAddr (Coin 230))
              Empty
              (Wdrl Map.empty)
              (Coin 770)
              (SlotNo 101)
              emptyUpdate
              Nothing
    aliceWit = makeWitnessVKey  tx2body alicePay
    tx = Tx txbody (Set.fromList [aliceWit]) Map.empty Nothing
  in ledgerState [tx] @?= Left [ InvalidWitness
                               , MissingWitnesses]

testEmptyInputSet :: Assertion
testEmptyInputSet =
  let
    aliceWithdrawal = Map.singleton (mkVKeyRwdAcnt aliceStake) (Coin 2000)
    tx = TxBody
           Set.empty
           (Seq.singleton $ TxOut aliceAddr (Coin 1000))
           Empty
           (Wdrl aliceWithdrawal)
           (Coin 1000)
           (SlotNo 0)
           emptyUpdate
           Nothing
    wits = makeWitnessesVKey tx [aliceStake]
    genesisWithReward' = changeReward genesis (mkVKeyRwdAcnt aliceStake) (Coin 2000)
    ls = asStateTransition
           (SlotNo 0) testPCs genesisWithReward' (Tx tx wits Map.empty Nothing) (Coin 0)
  in ls @?= Left [ InputSetEmpty ]

testFeeTooSmall :: Assertion
testFeeTooSmall =
  let
    tx = aliceGivesBobLovelace
           (TxIn genesisId 0)
           (Coin 3000) (Coin 1) (Coin 0) (Coin 0)
           []
           (SlotNo 100)
           [alicePay]
  in ledgerState [tx] @?=
       Left [ FeeTooSmall (minfee testPCs tx) (Coin 1) ]

testExpiredTx :: Assertion
testExpiredTx =
  let
    tx = aliceGivesBobLovelace
           (TxIn genesisId 0)
           (Coin 3000) (Coin 600) (Coin 0) (Coin 0)
           []
           (SlotNo 0)
           [alicePay]
  in asStateTransition (SlotNo 1) testPCs genesis tx (Coin 0) @?=
       Left [ Expired (SlotNo 0) (SlotNo 1) ]

testsInvalidLedger :: TestTree
testsInvalidLedger = testGroup "Tests with invalid transactions in ledger"
  [ testCase "Invalid Ledger - Alice tries to spend a nonexistent input" testSpendNonexistentInput
  , testCase "Invalid Ledger - Alice does not include a witness" testWitnessNotIncluded
  , testCase "Invalid Ledger - Alice tries to spend Bob's UTxO" testSpendNotOwnedUTxO
  , testCase "Invalid Ledger - Alice provides witness of wrong UTxO" testWitnessWrongUTxO
  , testCase "Invalid Ledger - Alice's transaction does not consume input" testEmptyInputSet
  , testCase "Invalid Ledger - Alice's fee is too small" testFeeTooSmall
  , testCase "Invalid Ledger - Alice's transaction has expired" testExpiredTx
  , testCase "Invalid Ledger - Invalid witnesses" testInvalidWintess
  , testCase "Invalid Ledger - No withdrawal witness" testWithdrawalNoWit
  , testCase "Invalid Ledger - Incorrect withdrawal amount" testWithdrawalWrongAmt
  ]

unitTests :: TestTree
unitTests = testGroup "Unit Tests"
  [ testsValidLedger, testsInvalidLedger, testsDParam ]