// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { AaveATokenAdaptor } from "src/modules/adaptors/Aave/AaveATokenAdaptor.sol";
import { IPool } from "src/interfaces/external/IPool.sol";
import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { ERC4626SharePriceOracle } from "src/base/ERC4626SharePriceOracle.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract ERC4626SharePriceOracleTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    AaveATokenAdaptor private aaveATokenAdaptor;
    MockDataFeed private usdcMockFeed;
    Cellar private cellar;
    ERC4626SharePriceOracle private sharePriceOracle;

    IPool private pool = IPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    uint32 private usdcPosition = 1;
    uint32 private aV2USDCPosition = 2;
    uint32 private debtUSDCPosition = 3;

    uint256 private initialAssets;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        usdcMockFeed = new MockDataFeed(USDC_USD_FEED);
        aaveATokenAdaptor = new AaveATokenAdaptor(address(pool), address(WETH), 1.05e18);

        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(IChainlinkAggregator(address(usdcMockFeed)).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(usdcMockFeed));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Setup Cellar:

        // Add adaptors and positions to the registry.
        registry.trustAdaptor(address(aaveATokenAdaptor));

        registry.trustPosition(aV2USDCPosition, address(aaveATokenAdaptor), abi.encode(address(aV2USDC)));
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(address(USDC)));

        uint256 minHealthFactor = 1.1e18;

        string memory cellarName = "Simple Aave Cellar V0.0";
        uint256 initialDeposit = 1e6;
        uint64 platformCut = 0.75e18;

        cellar = _createCellar(
            cellarName,
            USDC,
            aV2USDCPosition,
            abi.encode(minHealthFactor),
            initialDeposit,
            platformCut
        );

        cellar.addAdaptorToCatalogue(address(aaveATokenAdaptor));

        cellar.addPositionToCatalogue(usdcPosition);
        cellar.addPosition(1, usdcPosition, abi.encode(0), false);

        USDC.safeApprove(address(cellar), type(uint256).max);

        initialAssets = cellar.totalAssets();

        ERC4626 _target = ERC4626(address(cellar));
        uint64 _heartbeat = 1 days;
        uint64 _deviationTrigger = 0.0005e4;
        uint64 _gracePeriod = 60 * 60; // 1 hr
        uint16 _observationsToUse = 4; // TWAA duration is heartbeat * (observationsToUse - 1), so ~3 days.
        address _automationRegistry = address(this);

        // Setup share price oracle.
        sharePriceOracle = new ERC4626SharePriceOracle(
            _target,
            _heartbeat,
            _deviationTrigger,
            _gracePeriod,
            _observationsToUse,
            _automationRegistry
        );
    }

    function testHappyPath() external {
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));
        assertApproxEqAbs(
            aV2USDC.balanceOf(address(cellar)),
            assets + initialAssets,
            1,
            "Assets should have been deposited into Aave."
        );

        bool upkeepNeeded;
        bytes memory performData;
        // uint256 checkGas = gasleft();
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        // console.log("Gas used for checkUpkeep", checkGas - gasleft());
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        // uint256 performGas = gasleft();
        sharePriceOracle.performUpkeep(performData);
        // console.log("Gas Used for PerformUpkeep", performGas - gasleft());
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(!upkeepNeeded, "Upkeep should not be needed.");

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        // Advance time to 1 sec after grace period, and make sure we revert when trying to get TWAA,
        // until enough observations are added that this delayed entry is no longer affecting TWAA.
        bool checkNotSafeToUse;
        vm.warp(block.timestamp + 1 days + 3601);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        uint256 currentSharePrice = cellar.previewRedeem(1e6);

        // Get time weighted average share price.
        // uint256 gas = gasleft();
        (uint256 ans, uint256 timeWeightedAverageAnswer, bool notSafeToUse) = sharePriceOracle.getLatest();
        ans = ans.changeDecimals(18, 6);
        timeWeightedAverageAnswer = timeWeightedAverageAnswer.changeDecimals(18, 6);
        // console.log("Gas Used For getLatest", gas - gasleft());
        assertTrue(!notSafeToUse, "Should be safe to use");
        assertEq(ans, currentSharePrice, "Answer should be equal to current share price.");
        assertGt(currentSharePrice, timeWeightedAverageAnswer, "Current share price should be greater than TWASP.");
    }

    function testGetLatestPositiveYield() external {
        cellar.setHoldingPosition(usdcPosition);
        // Test latestAnswer over a 3 day period.
        uint64 dayOneYield = 1.001e4;
        uint64 dayTwoYield = 1.0005e4;
        uint64 dayThreeYield = 1.0005e4;
        bool checkNotSafeToUse;
        uint256 answer;
        uint256 twaa;

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 1, "Index should be 1");

        _passTimeAlterSharePriceAndUpkeep(1 days, dayOneYield);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 2, "Index should be 2");

        // Simulate deviation from share price triggers an update.
        _passTimeAlterSharePriceAndUpkeep(43_200, dayOneYield);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 2, "Index should be 2");

        // 12 hrs later, the timeDeltaSincePreviousObservation check should trigger an update.
        _passTimeAlterSharePriceAndUpkeep(43_200, dayTwoYield);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 3, "Index should be 3");

        _passTimeAlterSharePriceAndUpkeep(1 days, dayThreeYield);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 4, "Index should be 4");

        assertGt(answer, twaa, "Answer should be larger than TWAA since all yield was positive.");
    }

    function testGetLatestNegativeYield() external {
        cellar.setHoldingPosition(usdcPosition);
        // Test latestAnswer over a 3 day period.
        uint64 dayOneYield = 0.990e4;
        uint64 dayTwoYield = 0.9995e4;
        uint64 dayThreeYield = 0.9993e4;
        bool checkNotSafeToUse;
        uint256 answer;
        uint256 twaa;

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 1, "Index should be 1");

        _passTimeAlterSharePriceAndUpkeep(1 days, dayOneYield);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 2, "Index should be 2");

        // Simulate deviation from share price triggers an update.
        _passTimeAlterSharePriceAndUpkeep(43_200, dayOneYield);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 2, "Index should be 2");

        // 12 hrs later, the timeDeltaSincePreviousObservation check should trigger an update.
        _passTimeAlterSharePriceAndUpkeep(43_200, dayTwoYield);
        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 3, "Index should be 3");

        _passTimeAlterSharePriceAndUpkeep(1 days, dayThreeYield);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        assertEq(sharePriceOracle.currentIndex(), 4, "Index should be 4");

        assertGt(twaa, answer, "TWASS should be larger than answer since all yield was negative.");
    }

    function testStrategistForgetsToFillUpkeep(uint256 forgetTime) external {
        forgetTime = bound(forgetTime, 1, 3 days);
        cellar.setHoldingPosition(usdcPosition);
        bool checkNotSafeToUse;
        uint256 answer;
        uint256 twaa;

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        // Log TWAA details for 3 days, so that answer is usable.
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        // Upkeep becomes underfunded, and strategist forgets to fill it.
        _passTimeAlterSharePriceAndUpkeep(1 days + 3_600 + forgetTime, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        // Strategist refills upkeep with link and pricing can continue as normal once observations are written.
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");
    }

    function testSuppressedUpkeepAttack(uint256 suppressionTime) external {
        suppressionTime = bound(suppressionTime, 1, 3 days);
        cellar.setHoldingPosition(usdcPosition);
        bool checkNotSafeToUse;
        uint256 answer;
        uint256 twaa;

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        // Log TWAA details for 3 days, so that answer is usable.
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");

        // Attacker allows upkeep to go through.
        sharePriceOracle.performUpkeep(performData);

        // Another day passes.
        vm.warp(block.timestamp + 1 days);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Upkeep is needed, but attacker starts suppressing chainlink upkeeps.
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");

        // Attacker suppresses updates for heartbest + grace period + suppressionTime.
        vm.warp(block.timestamp + 1 days + 3_600 + suppressionTime);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Attacker finally allows upkeep to succeed.
        sharePriceOracle.performUpkeep(performData);

        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        // Must wait unitl observations are filled up with fresh data before we can start pricing again.
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);

        // Finally have enough observations so value is safe to use.
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");
    }

    function testSharePriceManipulationAttack(uint256 suppressionTime) external {
        suppressionTime = bound(suppressionTime, 1, 3 days);
        cellar.setHoldingPosition(usdcPosition);
        bool checkNotSafeToUse;
        uint256 answer;
        uint256 twaa;

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        // Log TWAA details for 3 days, so that answer is usable.
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        (uint256 answerBeforeAttack, uint256 twaaBeforeAttack, ) = sharePriceOracle.getLatest();

        // Assume an attack found some way to alter the target Cellar share price temporarily.
        // Attacker raises share price 10x, right before observation is complete.
        _passTimeAlterSharePriceAndUpkeep(1 days, 10e4);

        (answer, , ) = sharePriceOracle.getLatest();

        assertApproxEqRel(answer, 10 * answerBeforeAttack, 0.01e18, "Oracle answer should have been 10xed from attack");

        // Attacker is able to hold share price at 10x for 10 min.
        vm.warp(block.timestamp + 600);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);

        // Attacker returns share price to what it was before attack.
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(0.1e4, 1e4));

        // Upkeep should be needed due to deviation.
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();

        // TWAA calculation includes 3 days of good values, and 10 min of attacker bad values.
        assertApproxEqRel(
            twaa,
            twaaBeforeAttack,
            0.021e18,
            "Attack should have little effect on time weighted average share price."
        );

        // Also check that once this observations ends and we use the next one that TWAA is good as well.
        // Worst case scenario because total TWAP is 3 days, but inludes the 10 min
        // where attacker had elevated share price.
        _passTimeAlterSharePriceAndUpkeep(1 days - 600, 1e4);
        (answer, twaa, checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        assertApproxEqRel(
            twaa,
            twaaBeforeAttack,
            0.021e18,
            "Attack should have little effect on time weighted average share price."
        );
    }

    function testGracePeriod(uint256 delayOne, uint256 delayTwo, uint256 delayThree) external {
        cellar.setHoldingPosition(usdcPosition);

        uint256 gracePeriod = sharePriceOracle.gracePeriod();

        delayOne = bound(delayOne, 0, gracePeriod);
        delayTwo = bound(delayTwo, 0, gracePeriod - delayOne);
        delayThree = bound(delayThree, 0, gracePeriod - (delayOne + delayTwo));

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        _passTimeAlterSharePriceAndUpkeep(1 days + delayOne, 1e4);
        _passTimeAlterSharePriceAndUpkeep(1 days + delayTwo, 1e4);
        _passTimeAlterSharePriceAndUpkeep(1 days + delayThree, 1e4);

        (, , bool checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(!checkNotSafeToUse, "Value should be safe to use");

        // But if the next reading is delayed 1 more second than gracePeriod - (delayTwo + delayThree), pricing is not safe to use.
        uint256 unsafeDelay = 1 + (gracePeriod - (delayTwo + delayThree));
        _passTimeAlterSharePriceAndUpkeep(1 days + unsafeDelay, 1e4);

        (, , checkNotSafeToUse) = sharePriceOracle.getLatest();
        assertTrue(checkNotSafeToUse, "Value should not be safe to use");
    }

    function testOracleUpdatesFromDeviation() external {
        cellar.setHoldingPosition(usdcPosition);

        // Have user deposit into cellar.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        // Update share price so that it falls under the update deviation.
        vm.warp(block.timestamp + 600);

        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(!upkeepNeeded, "Upkeep should not be needed.");

        uint256 sharePriceMultiplier = 0.9994e4;
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier, 1e4));

        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 1, "Index should be 1");

        // Update share price so that it falls over the update deviation.
        vm.warp(block.timestamp + 600);

        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(!upkeepNeeded, "Upkeep should not be needed.");

        sharePriceMultiplier = 1.0006e4;
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier, 1e4));

        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 1, "Index should be 1");
    }

    function testTimeWeightedAverageAnswerWithDeviationUpdates(
        uint256 assets,
        uint256 sharePriceMultiplier0,
        uint256 sharePriceMultiplier1
    ) external {
        // Rebalance aV2USDC into USDC position.
        {
            Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromAaveV2(USDC, type(uint256).max);
            data[0] = Cellar.AdaptorCall({ adaptor: address(aaveATokenAdaptor), callData: adaptorCalls });
            // Perform callOnAdaptor.
            cellar.callOnAdaptor(data);
        }

        cellar.setHoldingPosition(usdcPosition);
        sharePriceMultiplier0 = bound(sharePriceMultiplier0, 0.2e4, 0.94e4);
        sharePriceMultiplier1 = bound(sharePriceMultiplier1, 1.06e4, 1.5e4);
        uint256 sharePriceMultiplier2 = sharePriceMultiplier0 / 2;
        uint256 sharePriceMultiplier3 = sharePriceMultiplier0 / 3;
        uint256 sharePriceMultiplier4 = sharePriceMultiplier0 / 4;
        uint256 sharePriceMultiplier5 = (sharePriceMultiplier1 * 1.1e4) / 1e4;
        uint256 sharePriceMultiplier6 = (sharePriceMultiplier1 * 1.2e4) / 1e4;
        uint256 sharePriceMultiplier7 = (sharePriceMultiplier1 * 1.3e4) / 1e4;
        sharePriceMultiplier0 = sharePriceMultiplier0 < 1e4 ? sharePriceMultiplier0 - 6 : sharePriceMultiplier0 + 6;
        sharePriceMultiplier1 = sharePriceMultiplier1 < 1e4 ? sharePriceMultiplier1 - 6 : sharePriceMultiplier1 + 6;
        sharePriceMultiplier2 = sharePriceMultiplier2 < 1e4 ? sharePriceMultiplier2 - 6 : sharePriceMultiplier2 + 6;
        sharePriceMultiplier3 = sharePriceMultiplier3 < 1e4 ? sharePriceMultiplier3 - 6 : sharePriceMultiplier3 + 6;
        sharePriceMultiplier4 = sharePriceMultiplier4 < 1e4 ? sharePriceMultiplier4 - 6 : sharePriceMultiplier4 + 6;
        sharePriceMultiplier5 = sharePriceMultiplier5 < 1e4 ? sharePriceMultiplier5 - 6 : sharePriceMultiplier5 + 6;
        sharePriceMultiplier6 = sharePriceMultiplier6 < 1e4 ? sharePriceMultiplier6 - 6 : sharePriceMultiplier6 + 6;
        sharePriceMultiplier7 = sharePriceMultiplier7 < 1e4 ? sharePriceMultiplier7 - 6 : sharePriceMultiplier7 + 6;

        // Have user deposit into cellar.
        assets = bound(assets, 0.1e6, 1_000_000_000e6);
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 1, "Wrong Current Index");

        uint256 startingCumulative = _calcCumulative(cellar, 0, (block.timestamp - 1));
        uint256 cumulative = startingCumulative;

        // Deviate outside threshold for first 12 hours
        vm.warp(block.timestamp + (1 days / 2));
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 2));
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier0, 1e4));
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 1, "Wrong Current Index");

        // For last 12 hours, reset to original share price.
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 2));
        _passTimeAlterSharePriceAndUpkeep((1 days / 2), sharePriceMultiplier1);

        assertEq(sharePriceOracle.currentIndex(), 2, "Wrong Current Index");

        // Deviate outside threshold for first 6 hours
        vm.warp(block.timestamp + (1 days / 4));
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 4));
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier2, 1e4));
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 2, "Wrong Current Index");

        // Deviate outside threshold for first 6-12 hours
        vm.warp(block.timestamp + (1 days / 4));
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 4));
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier3, 1e4));
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 2, "Wrong Current Index");

        // Deviate outside threshold for 12-18 hours
        vm.warp(block.timestamp + (1 days / 4));
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 4));
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier4, 1e4));
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 2, "Wrong Current Index");

        // For last 6 hours show a loss.
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 4));
        _passTimeAlterSharePriceAndUpkeep((1 days / 4), sharePriceMultiplier5);

        assertEq(sharePriceOracle.currentIndex(), 3, "Wrong Current Index");

        // Deviate outside threshold for first 18 hours
        vm.warp(block.timestamp + (18 * 3_600));
        cumulative = _calcCumulative(cellar, cumulative, (18 * 3_600));
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier6, 1e4));
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        assertEq(sharePriceOracle.currentIndex(), 3, "Wrong Current Index");

        // For last 6 hours earn no yield.
        cumulative = _calcCumulative(cellar, cumulative, (1 days / 4));
        _passTimeAlterSharePriceAndUpkeep((1 days / 4), sharePriceMultiplier7);

        assertEq(sharePriceOracle.currentIndex(), 4, "Wrong Current Index");

        (uint256 ans, uint256 twaa, bool notSafeToUse) = sharePriceOracle.getLatest();

        assertTrue(!notSafeToUse, "Answer should be safe to use.");
        uint256 expectedTWAA = (cumulative - startingCumulative) / 3 days;

        assertApproxEqAbs(twaa, expectedTWAA, 1, "Actual Time Weighted Average Answer should equal expected.");
        assertApproxEqAbs(
            cellar.previewRedeem(1e6),
            ans.changeDecimals(18, 6),
            1,
            "Actual share price should equal answer."
        );
    }

    function testMultipleReads() external {
        // Rebalance aV2USDC into USDC position.
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        {
            bytes[] memory adaptorCalls = new bytes[](1);
            adaptorCalls[0] = _createBytesDataToWithdrawFromAaveV2(USDC, type(uint256).max);
            data[0] = Cellar.AdaptorCall({ adaptor: address(aaveATokenAdaptor), callData: adaptorCalls });
        }
        // Perform callOnAdaptor.
        cellar.callOnAdaptor(data);

        cellar.setHoldingPosition(usdcPosition);

        // Have user deposit into cellar.
        uint256 assets = 1_000e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);

        uint256 answer;
        uint256 twaa;
        bool isNotSafeToUse;

        for (uint256 i; i < 30; ++i) {
            _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
            (answer, twaa, isNotSafeToUse) = sharePriceOracle.getLatest();
            answer = answer.changeDecimals(18, 6);
            twaa = twaa.changeDecimals(18, 6);
            assertEq(answer, 1e6, "Answer should be 1 USDC");
            assertEq(twaa, 1e6, "TWAA should be 1 USDC");
            assertTrue(!isNotSafeToUse, "Should be safe to use");
        }
    }

    function testGetLatestAnswer() external {
        bool upkeepNeeded;
        bytes memory performData;
        // uint256 checkGas = gasleft();
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        sharePriceOracle.performUpkeep(performData);

        // Fill oracle with observations.
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);
        _passTimeAlterSharePriceAndUpkeep(1 days, 1e4);

        bool isNotSafeToUse;
        (, isNotSafeToUse) = sharePriceOracle.getLatestAnswer();
        assertTrue(!isNotSafeToUse, "Answer should be safe to use.");

        // Make sure `isNotSafeToUse` is true if answer is stale.
        vm.warp(block.timestamp + (1 days + 3_601));
        (, isNotSafeToUse) = sharePriceOracle.getLatestAnswer();
        assertTrue(isNotSafeToUse, "Answer should not be safe to use.");
    }

    function testWrongPerformDataInputs() external {
        cellar.setHoldingPosition(usdcPosition);

        // Have user deposit into cellar.
        uint256 assets = 1e6;
        deal(address(USDC), address(this), assets);
        cellar.deposit(assets, address(this));

        // Call first performUpkeep on Cellar.
        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);

        // Try calling performUpkeep with a timestamp in the past.
        (uint224 ans, uint64 timestamp) = abi.decode(performData, (uint224, uint64));
        timestamp = timestamp - 100;
        performData = abi.encode(ans, timestamp);
        vm.expectRevert(
            bytes(abi.encodeWithSelector(ERC4626SharePriceOracle.ERC4626SharePriceOracle__StalePerformData.selector))
        );
        sharePriceOracle.performUpkeep(performData);

        // Try calling performUpkeep when no upkeep condition is met.
        (ans, timestamp) = abi.decode(performData, (uint224, uint64));
        timestamp = timestamp + 1_000;
        performData = abi.encode(ans, timestamp);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(ERC4626SharePriceOracle.ERC4626SharePriceOracle__NoUpkeepConditionMet.selector)
            )
        );
        sharePriceOracle.performUpkeep(performData);

        // Try calling performUpkeep from an address that is not the automation registry.
        address attacker = vm.addr(111);
        vm.startPrank(attacker);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    ERC4626SharePriceOracle.ERC4626SharePriceOracle__OnlyCallableByAutomationRegistry.selector
                )
            )
        );
        sharePriceOracle.performUpkeep(performData);
        vm.stopPrank();
    }

    function _passTimeAlterSharePriceAndUpkeep(uint256 timeToPass, uint256 sharePriceMultiplier) internal {
        vm.warp(block.timestamp + timeToPass);
        usdcMockFeed.setMockUpdatedAt(block.timestamp);
        deal(address(USDC), address(cellar), USDC.balanceOf(address(cellar)).mulDivDown(sharePriceMultiplier, 1e4));

        bool upkeepNeeded;
        bytes memory performData;
        (upkeepNeeded, performData) = sharePriceOracle.checkUpkeep(abi.encode(0));
        assertTrue(upkeepNeeded, "Upkeep should be needed.");
        sharePriceOracle.performUpkeep(performData);
    }

    function _calcCumulative(Cellar target, uint256 previous, uint256 timePassed) internal view returns (uint256) {
        uint256 oneShare = 10 ** target.decimals();
        uint256 totalAssets = target.totalAssets().changeDecimals(
            target.decimals(),
            sharePriceOracle.ORACLE_DECIMALS()
        );
        return previous + totalAssets.mulDivDown(oneShare * timePassed, target.totalSupply());
    }
}
