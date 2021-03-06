pragma solidity 0.5.15;

import "./interfaces/IAaveLendingPool.sol";
import "./interfaces/IADai.sol";
import "./interfaces/INoLossDao.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@nomiclabs/buidler/console.sol";


/** @title Pooled Deposits Contract*/
contract PoolDeposits {
    using SafeMath for uint256;

    address public admin;
    uint256 public totalDepositedDai;
    mapping(address => uint256) public depositedDai;

    uint256 public proposalAmount; // Stake required to submit a proposal
    uint256 public daoMembershipMinimum; // Check if 1000 DAI is acceptable or set it

    ///////// DEFI Contrcats ///////////
    IERC20 public daiContract;
    IAaveLendingPool public aaveLendingContract;
    IADai public adaiContract;
    INoLossDao public noLossDaoContract; // should we be able to change this as admin.
    ILendingPoolAddressesProvider public provider;
    address public aaveLendingContractCore;

    //////// EMERGENCY MODULE ONLY ///////
    uint256 public emergencyVoteAmount;
    mapping(address => bool) public emergencyVoted;
    mapping(address => uint256) public timeJoined;
    bool public isEmergencyState;

    ///////// Events ///////////
    event DepositAdded(address indexed user, uint256 amount);
    event ProposalAdded(
        address indexed benefactor,
        uint256 indexed proposalId,
        string proposalIdentifier
    );
    event DepositWithdrawn(address indexed user);
    event ProposalWithdrawn(address indexed benefactor);
    event InterestSent(address indexed user, uint256 amount);

    ///////// Emergency Events ///////////
    event EmergencyStateReached(
        address indexed user,
        uint256 timeStamp,
        uint256 totalDaiInContract,
        uint256 totalEmergencyVotes
    );
    event EmergencyVote(address indexed user, uint256 emergencyVoteAmount);
    event RemoveEmergencyVote(
        address indexed user,
        uint256 emergencyVoteAmount
    );
    event EmergencyWithdrawl(address indexed user);

    ///////////////////////////////////////////////////////////////////
    //////// EMERGENCY MODIFIERS //////////////////////////////////////
    ///////////////////////////////////////////////////////////////////
    modifier emergencyEnacted() {
        require(
            totalDepositedDai < emergencyVoteAmount.mul(2), //safe 50%
            "50% of total pool needs to have voted for emergency state"
        );
        require(
            totalDepositedDai > 200000000000000000000000, //200 000 DAI needed in contract
            "200 000DAI required in pool before emergency state can be declared"
        );
        _;
    }
    modifier noEmergencyVoteYet() {
        require(
            emergencyVoted[msg.sender] == false,
            "Already voted for emergency"
        );
        _;
    }
    modifier stableState() {
        require(isEmergencyState == false, "State of emergency declared");
        _;
    }
    modifier emergencyState() {
        require(isEmergencyState == true, "State of emergency not declared");
        _;
    }
    // Required to be part of the pool for 100 days. Make it costly to borrow and put into state of emergency.
    modifier eligibleToEmergencyVote() {
        require(
            timeJoined[msg.sender].add(8640000) < now,
            "Need to have joined for 100days to vote an emergency"
        );
        _;
    }
    ////////////////////////////////////////////////////////////////////////

    ////////////////////////////////////
    //////// Modifiers /////////////////
    ////////////////////////////////////
    modifier noLossDaoContractOnly() {
        require(
            address(noLossDaoContract) == msg.sender, // Is this a valid way of getting the address?
            "function can only be called by no Loss Dao contract"
        );
        _;
    }

    modifier allowanceAvailable(uint256 amount) {
        require(
            amount <= daiContract.allowance(msg.sender, address(this)), // checking the pool deposits contract
            "amount not available"
        );
        _;
    }

    modifier requiredDai(uint256 amount) {
        require(
            daiContract.balanceOf(msg.sender) >= amount,
            "User does not have enough DAI"
        );
        _;
    }

    modifier blankUser() {
        require(depositedDai[msg.sender] == 0, "Person is already a user");
        _;
    }

    modifier userStaked() {
        require(depositedDai[msg.sender] > 0, "User has no stake");
        _;
    }

    modifier thresholdAmount(uint256 amount) {
        require(
            amount > daoMembershipMinimum,
            "Minimum amount of 1000 DAI required to join pool"
        );
        _;
    }

    modifier validInterestSplitInput(
        address[] memory addresses,
        uint256[] memory percentages
    ) {
        require(
            addresses.length == percentages.length,
            "Input length not equal"
        );
        _;
    }

    /***************
    Contract set-up: Not Upgradaable
    ***************/
    constructor(
        address daiAddress,
        address aDaiAddress,
        // lendingPoolAddressProvider should be one of below depending on deployment
        // kovan 0x506B0B2CF20FAA8f38a4E2B524EE43e1f4458Cc5
        // mainnet 0x24a42fD28C976A61Df5D00D0599C34c4f90748c8
        address lendingPoolAddressProvider,
        address noLossDaoAddress,
        uint256 _proposalAmount, // Set the amount required to ensure quality DAOs.
        uint256 _daoMembershipMinimum // Set min threshold to join before voting credits build up. Protects against sybil but increases hurdle to membership // Protects against sybil but increases hurdle to membership
    ) public {
        daiContract = IERC20(daiAddress);
        provider = ILendingPoolAddressesProvider(lendingPoolAddressProvider);
        adaiContract = IADai(aDaiAddress);
        noLossDaoContract = INoLossDao(noLossDaoAddress);
        admin = msg.sender;
        proposalAmount = _proposalAmount; // if we want this configurable put in other contract
        isEmergencyState = false;
        daoMembershipMinimum = _daoMembershipMinimum; // 1000 DAI [10 **21 as default] recommended
    }

    /// @dev allows the proposalAmount (amount proposal has to stake to enter the pool) to be configurable
    /// @param amount new proposalAmount
    function changeProposalAmount(uint256 amount)
        external
        noLossDaoContractOnly
    {
        proposalAmount = amount;
    }

    // Will error if not enough credit from user
    function usersVotingCreditAndVoteIncentiveState(address user)
        external
        view
        returns (uint256 totalVoiceCredits, uint256 voteIncentiveStake)
    {
        return (
            depositedDai[user].sub(daoMembershipMinimum),
            // We take 20% = (100% - 80%) of the minimum required to vote to make the system more fair.
            depositedDai[user].sub(daoMembershipMinimum.mul(80).div(100)) // this is configurable
        );
    }

    /// @dev Internal function completing the actual deposit to Aave and crediting users account
    /// @param amount amount being deosited into pool
    function _depositFunds(uint256 amount) internal {
        aaveLendingContract = IAaveLendingPool(provider.getLendingPool());
        aaveLendingContractCore = provider.getLendingPoolCore();

        daiContract.transferFrom(msg.sender, address(this), amount);
        daiContract.approve(aaveLendingContractCore, amount);
        aaveLendingContract.deposit(address(daiContract), amount, 30);

        timeJoined[msg.sender] = now;
        depositedDai[msg.sender] = amount;
        totalDepositedDai = totalDepositedDai.add(amount);
    }

    /// @dev Internal function completing the actual redemption from Aave and sendinding funds back to user
    function _withdrawFunds() internal {
        uint256 amount = depositedDai[msg.sender];
        _removeEmergencyVote();

        depositedDai[msg.sender] = 0;
        totalDepositedDai = totalDepositedDai.sub(amount);

        adaiContract.redeem(amount);
        daiContract.transfer(msg.sender, amount);
    }

    /// @dev Lets a user join DAOcare through depositing
    /// @param amount the user wants to deposit into the DAOcare pool
    function deposit(uint256 amount)
        external
        blankUser
        allowanceAvailable(amount)
        requiredDai(amount)
        thresholdAmount(amount)
        stableState
    {
        _depositFunds(amount);
        noLossDaoContract.noLossDeposit(msg.sender);
        emit DepositAdded(msg.sender, amount);
    }

    /// @dev Lets a user withdraw their original amount sent to DAOcare
    /// Calls the NoLossDao conrrtact to determine eligibility to withdraw
    /// Withdraws the proposalAmount (50DAI) if succesful
    function withdrawDeposit() external userStaked {
        _withdrawFunds();
        noLossDaoContract.noLossWithdraw(msg.sender);
        emit DepositWithdrawn(msg.sender);
    }

    /// @dev Lets user create proposal
    /// @param proposalIdentifier hash of the users new proposal
    function createProposal(string calldata proposalIdentifier)
        external
        blankUser
        allowanceAvailable(proposalAmount)
        requiredDai(proposalAmount)
        stableState
        returns (uint256 newProposalId)
    {
        _depositFunds(proposalAmount);
        uint256 proposalId = noLossDaoContract.noLossCreateProposal(
            proposalIdentifier,
            msg.sender
        );
        emit ProposalAdded(msg.sender, proposalId, proposalIdentifier);
        return proposalId;
    }

    /// @dev Lets user withdraw proposal
    function withdrawProposal() external {
        _withdrawFunds();
        noLossDaoContract.noLossWithdrawProposal(msg.sender);
        emit ProposalWithdrawn(msg.sender);
    }

    function interestAvailable() public view returns (uint256 amountToRedeem) {
        amountToRedeem = adaiContract.balanceOf(address(this)).sub(
            totalDepositedDai
        );
    }

    function payoutVotingIncentive(address voter, uint256 payoutAmount)
        external
        noLossDaoContractOnly
    {
        require(
            interestAvailable() >= payoutAmount,
            "Interest isn't available"
        );
        adaiContract.redeem(payoutAmount);

        daiContract.transfer(voter, payoutAmount);
        emit InterestSent(voter, payoutAmount);
    }

    //////////////////////////////////////////////////
    //////// EMERGENCY MODULE FUNCTIONS  //////////////
    ///////////////////////////////////////////////////

    /// @dev Declares a state of emergency and enables emergency withdrawls that are not dependant on any external smart contracts
    function declareStateOfEmergency() external emergencyEnacted {
        isEmergencyState = true;
        emit EmergencyStateReached(
            msg.sender,
            now,
            totalDepositedDai,
            emergencyVoteAmount
        );
    }

    /// @dev Immediately lets yoou withdraw your funds in an state of emergency
    function emergencyWithdraw() external userStaked emergencyState {
        _withdrawFunds();
        emit EmergencyWithdrawl(msg.sender);
    }

    /// @dev lets users vote that the a state of emergency should be decalred
    /// Requires time lock here to defeat flash loan punks
    function voteEmergency()
        external
        userStaked
        noEmergencyVoteYet
        eligibleToEmergencyVote
    {
        emergencyVoted[msg.sender] = true;
        emergencyVoteAmount = emergencyVoteAmount.add(depositedDai[msg.sender]);
        emit EmergencyVote(msg.sender, depositedDai[msg.sender]);
    }

    /// @dev Internal function removing a users emergency vote if they leave the pool
    function _removeEmergencyVote() internal {
        bool status = emergencyVoted[msg.sender];
        emergencyVoted[msg.sender] = false;
        if (status == true) {
            emergencyVoteAmount = emergencyVoteAmount.sub(
                depositedDai[msg.sender]
            );
            emit RemoveEmergencyVote(msg.sender, depositedDai[msg.sender]);
        }
    }
}
