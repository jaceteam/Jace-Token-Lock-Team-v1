// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

 /**
 * @title JaceTokenLockTeamV1
 * @dev Smart contract for locking and distributing JACE tokens to team members with vesting schedules.
 * Team members can lock their JACE tokens and claim vested tokens after specified lockup periods.
 * The contract ensures that only team members can interact with certain functions and guards against reentrancy attacks.
 * It provides transparency and security in managing token distribution to team members with vesting requirements.
 * @notice For more information, visit https://jace.team/jace-tokenomics
 * @notice For support or inquiries, contact dev@jace.team
 */
contract JaceTokenLockTeamV1 is ReentrancyGuard {

    // SafeERC20 is a library from OpenZeppelin Contracts, ensuring safe ERC20 token transfers.
    using SafeERC20 for IERC20;

    // JACE token contract instance.
    IERC20 jaceToken = IERC20(0x0305ce989f3055a6Da8955fc52b615b0086A2157);

    // This variable signifies the cycle proportion of tokens that becomes available for claiming, calculated as a percentage of the total locked tokens, over the entire lockup period.
    uint constant releasePercentEachCycleR10 = 10; // 10%

    // This variable signifies the cycle proportion of tokens that becomes available for claiming, calculated as a percentage of the total locked tokens, over the entire lockup period.
    uint constant releasePercentEachCycleR5 = 20; // 20%

    // This variable provides the times when a percentage of the locked tokens is released.
    uint[10] tokensLockupPeriodCycles = [
        1830699763, // January, 2028
        1841672563, // May, 2028
        1853595763, // September, 2028
        1862044963, // January, 2029
        1873701763, // May, 2029
        1883551363, // September, 2029
        1894601743, // January, 2030
        1905401743, // May, 2030
        1914740143, // September, 2030
        1926922543 // January, 2031
    ];

    // An array of wallet addresses belonging to team members.
    address[8] teamMemberWalletAddresses = [
        0x0DfcB3F2D718EB1F2057606Bea35635dB1C0914D, // Support & Maintenance Team
        0xA8252CCC523Da9717457fFA926c50e81a9F22A8A, // Investment Team
        0x061A66982C4d640c1cee6dce07f5af506aC03C46, // Marketing & Outreach Team
        0x45F84f30BEa00F1074d9aA1bA4bDFEc0D56628a4, // Business Strategy Team
        0xA95adB26162724EC38361d7eDE11Fb7fE9E571D9, // Engineering Team
        0x0B7355af3B364eb3046431b9f6f9c9afcC832860, // Product Design Team
        0xa3BBe3E7DC0566De4eF3EB7c4C1C889f443bC798, // Research & Development Team
        0xC523bed68D08dbC411edE8ffBE4A9444eA19488C // Project Leadership Team
    ];

    // Admin address.
    address immutable admin;

    // Struct to represent vesting details for each team member.
    struct Vesting {
        // release stages of vesting: Can be either 5 or 10, indicating the duration of the vesting period.
        uint releaseStages;

        // Total amount of locked JACE tokens.
        uint totalLockedJace;

        // Represents the cumulative amount of JACE tokens that have been claimed by the team members up to the current point in time.
        uint totalClaimed;
    }

    // Mapping to associate each team member's address with their Vesting details.
    mapping(address => Vesting) teamMemberVesting;

    // Event emitted when a team member locks JACE tokens.
    event JaceTokensLocked(address indexed teamMember, uint amountLocked);

    // Event emitted when a team member successfully claims their JACE tokens after the lockup period.
    event JaceTokensClaimed(address indexed recipient, uint amountJace);

    // Event emitted when the admin withdraws the remaining JACE tokens after 30 days have passed since the last release time.
    event RemainingJaceTokensWithdrawByAdmin(address indexed withdrawAddress, uint withdrawAmount);

    constructor() {
        admin = msg.sender;
    }

    // Modifier to restrict access to admin.
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    // Modifier to restrict access to team members.
    modifier onlyTeamMember() {
        bool isTeamMember = false;
        for (uint i = 0; i < teamMemberWalletAddresses.length; i++) {
            if (teamMemberWalletAddresses[i] == msg.sender) {
                isTeamMember = true;
                break;
            }
        }
        require(isTeamMember, "Only team members can call this function");
        _;
    }

    // This function retrieves essential details about the contract.
    function getContractDetails() external view
    returns (
        uint _contractJaceBalance,
        uint[10] memory _tokensLockupPeriodCycles,
        address[8] memory _teamMemberWalletAddresses
    ) {
        return (
            jaceToken.balanceOf(address(this)),
            tokensLockupPeriodCycles,
            teamMemberWalletAddresses
        );
    }

    // Allows a team member to lock a specified amount of JACE tokens.
    function lockJaceTokens(uint _jaceAmountToLock) external onlyTeamMember nonReentrant returns (bool) {
        require(_jaceAmountToLock > 0, "Amount must be greater than 0");

        require(jaceToken.balanceOf(msg.sender) >= _jaceAmountToLock, "Insufficient JACE token");

        require(_jaceAmountToLock <= jaceToken.allowance(msg.sender, address(this)), "Make sure to add enough allowance");

        jaceToken.safeTransferFrom(msg.sender, address(this), _jaceAmountToLock);

        if (teamMemberVesting[msg.sender].totalLockedJace > 0) {
            teamMemberVesting[msg.sender].totalLockedJace += _jaceAmountToLock;
            teamMemberVesting[msg.sender].releaseStages = teamMemberVesting[msg.sender].totalLockedJace < 2000000 ether ? 5 : 10;
        } else {
            teamMemberVesting[msg.sender] = Vesting(
                _jaceAmountToLock < 2000000 ether ? 5 : 10,
                _jaceAmountToLock,
                0
            );
        }

        emit JaceTokensLocked(msg.sender, _jaceAmountToLock); 

        return true;
    }

    /*
    * Allows a team member to claim their allocated JACE tokens after the lockup period.
    * Calculates claimable tokens based on the release stages and percentage released.
    */
    function claimJaceTokens() external onlyTeamMember nonReentrant {
        require(teamMemberVesting[msg.sender].totalLockedJace > 0, "Nothing to claim");

        require(tokensLockupPeriodCycles[0] <= block.timestamp, "Lockup period has not ended yet");
        
        require(teamMemberVesting[msg.sender].totalClaimed < teamMemberVesting[msg.sender].totalLockedJace, "Already claimed");

        uint releasePercentEachCycle = (teamMemberVesting[msg.sender].releaseStages == 5) ? releasePercentEachCycleR5 : releasePercentEachCycleR10;

        uint claimableTokens = 0;
        for (uint i = 0; i < teamMemberVesting[msg.sender].releaseStages; i++) {
            if (tokensLockupPeriodCycles[i] <= block.timestamp) {
                claimableTokens += teamMemberVesting[msg.sender].totalLockedJace * releasePercentEachCycle / 100;
            }
        }
        
        claimableTokens -= teamMemberVesting[msg.sender].totalClaimed;

        require(claimableTokens > 0, "Nothing to claim");

        teamMemberVesting[msg.sender].totalClaimed += claimableTokens;
           
        jaceToken.safeTransfer(msg.sender, claimableTokens);

        emit JaceTokensClaimed(msg.sender, claimableTokens);
    }

    // Allows the admin to withdraw any remaining JACE tokens from the contract after a specified period following the end of the last release cycle.
    function withdrawRemainingTokens(address _to) external onlyAdmin {
        require (tokensLockupPeriodCycles[9] + 30 days <= block.timestamp, "Lockup period for the 10th cycle has not elapsed yet");

        require(_to != address(0), "Invalid recipient address");

        uint withdrawAmount = jaceToken.balanceOf(address(this));
        require(withdrawAmount > 0, "Nothing to transfer");

        jaceToken.safeTransfer(_to, withdrawAmount);

        emit RemainingJaceTokensWithdrawByAdmin(_to, withdrawAmount);
    }

    // Getting team member vesting details.
    function getTeamMemberVetsingDetails(address walletAddress) external view returns (uint _totalLockedJace, uint _totalClaimed, uint _releaseStages) {
        Vesting memory vestingInfo = teamMemberVesting[walletAddress];
        _releaseStages = vestingInfo.releaseStages;
        _totalLockedJace = vestingInfo.totalLockedJace;
        _totalClaimed = vestingInfo.totalClaimed;

        return (_totalLockedJace, _totalClaimed, _releaseStages);
    }
}