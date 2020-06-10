pragma solidity 0.5.15;

// import "./interfaces/IERC20.sol";
import "./interfaces/IAaveLendingPool.sol";
import "./interfaces/IADai.sol";
import "./interfaces/IPoolDeposits.sol";
import "@nomiclabs/buidler/console.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";

/** @title No Loss Dao Contract. */
contract NoLossDao_v0 is Initializable {
    using SafeMath for uint256;

    //////// MASTER //////////////
    address public admin;

    //////// Iteration specific //////////
    uint256 public votingInterval;
    uint256 public proposalIteration;

    ///////// Proposal specific ///////////
    uint256 public proposalId;
    uint256 public proposalDeadline; // keeping track of time
    mapping(uint256 => string) public proposalIdentifier;
    mapping(address => uint256) public benefactorsProposal; // benefactor -> proposal id
    mapping(uint256 => address) public proposalOwner; // proposal id -> benefactor (1:1 mapping)
    enum ProposalState {DoesNotExist, Withdrawn, Active}
    mapping(uint256 => ProposalState) public state; // ProposalId to current state

    //////// User specific //////////
    mapping(address => uint256) public iterationJoined; // Which iteration did user join DAO
    mapping(uint256 => mapping(address => bool)) public userVotedThisIteration; // iteration -> user -> has voted?
    mapping(uint256 => mapping(address => mapping(uint256 => bool)))
        public hasUserVotedForProposalIteration; /// iteration -> userAddress -> proposalId -> bool
    mapping(uint256 => mapping(address => mapping(uint256 => uint256)))
        public votesPerProposalForUser; // iteration -> user -> chosen project -> votes
    mapping(uint256 => mapping(address => uint256)) public usersVoteCredit; // iteration -> address -> credit

    //////// DAO / VOTE specific //////////
    mapping(uint256 => mapping(uint256 => uint256)) public proposalVotes; /// iteration -> proposalId -> num votes
    mapping(uint256 => uint256) public topProject;
    mapping(address => address) public voteDelegations; // For vote proxy
    mapping(uint256 => uint256) public totalStakedVoteIncentiveInIteration;
    mapping(uint256 => uint256) public totalIterationVotePayout;
    mapping(address => bool) public usersWhiteListedToVote;

    // As a safty mechanism a whitelist of members can be activated.
    bool public isWhiteListActive;

    ///////// DEFI Contrcats ///////////
    IPoolDeposits public depositContract;

    // Crrate blank 256 arrays of fixed length for upgradability.

    ///////// Events ///////////
    event VoteDelegated(address indexed user, address delegatedTo);
    event VotedDirect(
        address indexed user,
        uint256 indexed iteration,
        uint256 indexed proposalId,
        uint256 amount,
        uint256 sqrt
    );
    event VotedViaProxy(
        address indexed proxy,
        address user,
        uint256 indexed iteration,
        uint256 indexed proposalId,
        uint256 amount,
        uint256 sqrt
    );
    event IterationChanged(
        uint256 indexed newIterationId,
        address miner,
        uint256 timeStamp
    );
    event IterationWinner(
        uint256 indexed propsalIteration,
        address indexed winner,
        uint256 indexed projectId
    );
    event InterestConfigChanged(
        address[] addresses,
        uint256[] percentages,
        uint256 iteration
    );
    // Test these events
    event ProposalActive(
        uint256 indexed proposalId,
        address benefactor,
        uint256 iteration
    );
    event ProposalWithdrawn(uint256 indexed proposalId, uint256 iteration);

    ////////////////////////////////////
    //////// Modifiers /////////////////
    ////////////////////////////////////
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier userStaked(address givenAddress) {
        require(
            depositContract.depositedDai(givenAddress) > 0,
            "User has no stake"
        );
        _;
    }

    modifier noVoteYet(address givenAddress) {
        require(
            userVotedThisIteration[proposalIteration][givenAddress] == false,
            "User already voted this iteration"
        );
        _;
    }

    modifier quadraticCorrect(uint256 amount, uint256 sqrt) {
        require(sqrt.mul(sqrt) == amount, "Square root incorrect");
        require(amount > 0, "Cannot vote with 0");
        _;
    }

    modifier noVoteYetOnThisProposal(
        address givenAddress,
        uint256 proposalIdToVoteFor
    ) {
        require(
            !hasUserVotedForProposalIteration[proposalIteration][givenAddress][proposalIdToVoteFor],
            "Already voted on this proposal"
        );
        _;
    }

    modifier userHasActiveProposal(address givenAddress) {
        require(
            state[benefactorsProposal[givenAddress]] == ProposalState.Active,
            "User proposal does not exist"
        );
        _;
    }

    modifier userHasNoActiveProposal(address givenAddress) {
        require(
            state[benefactorsProposal[givenAddress]] != ProposalState.Active,
            "User has an active proposal"
        );
        _;
    }

    modifier userHasNoProposal(address givenAddress) {
        require(benefactorsProposal[givenAddress] == 0, "User has a proposal");
        _;
    }

    modifier proposalActive(uint256 propId) {
        require(
            state[propId] == ProposalState.Active,
            "Proposal is not active"
        );
        _;
    }

    modifier proxyRight(address delegatedFrom) {
        require(
            voteDelegations[delegatedFrom] == msg.sender,
            "User does not have proxy right"
        );
        _;
    }

    modifier isEligibleToVote(address user) {
        _isEligibleToVote(user);
        _;
    }

    // /**
    //  * @notice Modifier to only allow updates by the VRFCoordinator contract
    //  */
    // modifier onlyVRFCoordinator {
    //     require(
    //         msg.sender == vrfCoordinator,
    //         "Fulfillment only allowed by VRFCoordinator"
    //     );
    //     _;
    // }

    // We reset the iteration back to zero when a user leaves. Means this modifier will no longer protect.
    // But, its okay because it cannot be exploited. When 0, the user will have zero deposit.
    // Therefore that modifier will always catch them in that case :)
    modifier joinedInTime(address givenAddress) {
        require(
            iterationJoined[givenAddress] < proposalIteration,
            "User only eligible to vote next iteration"
        );
        _;
    }

    modifier lockInFulfilled(address givenAddress) {
        require(
            iterationJoined[givenAddress] + 2 < proposalIteration,
            "Benefactor has not fulfilled the minimum lockin period of 2 iterations"
        );
        _;
    }
    modifier iterationElapsed() {
        require(proposalDeadline < now, "iteration interval not ended");
        _;
    }

    modifier depositContractOnly() {
        require(
            address(depositContract) == msg.sender, // Is this a valid way of getting the address?
            "function can only be called by deposit contract"
        );
        _;
    }

    ////////////////////////////////////
    //////// SETUP CONTRACT////////////
    //// NOTE: Upgradable at the moment
    function initialize(address depositContractAddress, uint256 _votingInterval)
        public
        initializer
    {
        depositContract = IPoolDeposits(depositContractAddress);
        admin = msg.sender;
        votingInterval = _votingInterval;
        proposalDeadline = now.add(_votingInterval); //NOTE: THIS should be shorter for the first no voting iteration

        emit IterationChanged(0, msg.sender, now);
    }

    ///////////////////////////////////
    /////// Config functions //////////
    ///////////////////////////////////

    /// @dev Changes the time iteration  between intervals
    /// @param newInterval new time interval between interations
    function changeVotingInterval(uint256 newInterval) public onlyAdmin {
        votingInterval = newInterval;
    }

    /// @dev Changes the amount required to stake for new proposal
    /// @param amount how much new amount is.
    function changeProposalStakingAmount(uint256 amount) public onlyAdmin {
        depositContract.changeProposalAmount(amount);
    }

    /// @dev Sets whitelist voting
    /// @param _isWhiteListActive value to set it to.
    function setWhiteListVotingOnly(bool _isWhiteListActive) public onlyAdmin {
        isWhiteListActive = _isWhiteListActive;
    }

    // NOTE: This function can be upgraded in future versions (or left out if sybil attack isn't a big issue)
    //       In future versions more complicated membership process and requirements can be implemented. For v0 an admin function makes sense. - launch early and iterate ;)
    function whiteListUsers(address[] memory usersToWhitelist)
        public
        onlyAdmin
    {
        for (uint8 i = 0; i < usersToWhitelist.length; ++i) {
            usersWhiteListedToVote[usersToWhitelist[i]] = true;
        }
    }

    function blackListUsers(address[] memory usersToBlacklist)
        public
        onlyAdmin
    {
        for (uint8 i = 0; i < usersToBlacklist.length; ++i) {
            usersWhiteListedToVote[usersToBlacklist[i]] = false;
        }
    }

    function _isEligibleToVote(address user) internal {
        if (isWhiteListActive) {
            require(
                usersWhiteListedToVote[user],
                "whitelist is active and user not on whitelist"
            );
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////// Deposit & withdraw function for users //////////
    ////////and proposal holders (benefactors) /////////////
    ////////////////////////////////////////////////////////

    /// @dev Checks whether user is eligible deposit and sets the proposal iteration joined, to the current iteration
    /// @param userAddress address of the user wanting to deposit
    /// @return boolean whether the above executes successfully
    function noLossDeposit(address userAddress)
        external
        depositContractOnly
        userHasNoProposal(userAddress) // Checks they are not a benefactor
        returns (bool)
    {
        iterationJoined[userAddress] = proposalIteration;
        return true;
    }

    /// @dev Checks whether user is eligible to withdraw their deposit and sets the proposal iteration joined to zero
    /// @param userAddress address of the user wanting to withdraw
    /// @return boolean whether the above executes successfully
    function noLossWithdraw(address userAddress)
        external
        depositContractOnly
        noVoteYet(userAddress)
        userHasNoProposal(userAddress)
        returns (bool)
    {
        iterationJoined[userAddress] = 0;
        return true;
    }

    /// @dev Checks whether user is eligible to create a proposal then creates it. Executes a range of logic to add the new propsal (increments proposal ID, sets proposal owner, sets iteration joined, etc...)
    /// @param _proposalIdentifier Hash of the proposal text
    /// @param benefactorAddress address of benefactor creating proposal
    /// @return boolean whether the above executes successfully
    function noLossCreateProposal(
        string calldata _proposalIdentifier,
        address benefactorAddress
    ) external depositContractOnly returns (uint256 newProposalId) {
        proposalId = proposalId.add(1);

        proposalIdentifier[proposalId] = _proposalIdentifier;
        proposalOwner[proposalId] = benefactorAddress;
        benefactorsProposal[benefactorAddress] = proposalId;
        state[proposalId] = ProposalState.Active;
        iterationJoined[benefactorAddress] = proposalIteration;
        emit ProposalActive(proposalId, benefactorAddress, proposalIteration);
        return proposalId;
    }

    /// @dev Checks whether user is eligible to withdraw their proposal
    /// Sets the state of the users proposal to withdrawn
    /// resets the iteration of user joined back to 0
    /// @param benefactorAddress address of benefactor withdrawing proposal
    /// @return boolean whether the above is possible
    function noLossWithdrawProposal(address benefactorAddress)
        external
        depositContractOnly
        userHasActiveProposal(benefactorAddress)
        lockInFulfilled(benefactorAddress)
        returns (bool)
    {
        uint256 benefactorsProposalId = benefactorsProposal[benefactorAddress];
        iterationJoined[benefactorAddress] = 0;
        state[benefactorsProposalId] = ProposalState.Withdrawn;
        emit ProposalWithdrawn(benefactorsProposalId, proposalIteration);
        return true;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////// DAO voting functionality  //////////////////////
    ////////////////////////////////////////////////////////

    function _resetUsersVotingCreditIfFirstVoteThisIteration(
        address givenAddress
    ) internal {
        if (!userVotedThisIteration[proposalIteration][givenAddress]) {
            uint256 usersVoteIncentiveStake;
            (
                usersVoteCredit[proposalIteration][givenAddress],
                // NOTE: Users can only change their deposit through a complete withdrawl and new depsit
                // This means this value will always be constant and set correctly again if the above case occurs
                usersVoteIncentiveStake
            ) = depositContract.usersVotingCreditAndVoteIncentiveState(
                givenAddress
            );

            userVotedThisIteration[proposalIteration][givenAddress] = true;
            // NOTE: no need for safemath here.
            totalStakedVoteIncentiveInIteration[proposalIteration] =
                totalStakedVoteIncentiveInIteration[proposalIteration] +
                usersVoteIncentiveStake;

            // add voice credit amount here for user.
            // add same total amount for variable
            // IF person voted last iteration, trigger payout\
            // Since you can only vote on iteration 1 at earliest, proposalIteration - 1 should be safe
            if (userVotedThisIteration[proposalIteration - 1][givenAddress]) {
                // give them payout of interest earned during iteration that is proportional to the number of people who voted.


                    uint256 amountPayedAsParticipationIncentive
                 = totalIterationVotePayout[proposalIteration - 1]
                    .mul(usersVoteIncentiveStake)
                    .div(
                    totalStakedVoteIncentiveInIteration[proposalIteration - 1]
                );
                depositContract.payoutVotingIncentive(
                    givenAddress,
                    amountPayedAsParticipationIncentive
                );
            }
        }
    }

    /// @dev Allows user to delegate their full voting power to another user
    /// @param delegatedAddress the address to which you are delegating your voting rights
    function delegateVoting(address delegatedAddress)
        external
        userStaked(msg.sender)
        userHasNoActiveProposal(msg.sender)
        userHasNoActiveProposal(delegatedAddress)
    {
        voteDelegations[msg.sender] = delegatedAddress;
        emit VoteDelegated(msg.sender, delegatedAddress);
    }

    /// @dev Allows user to vote for an active proposal. Once voted they cannot withdraw till next iteration.
    /// @param proposalIdToVoteFor Id of the proposal they are voting for
    function voteDirect(
        uint256 proposalIdToVoteFor, // breaking change -> function name change from vote to voteDirect
        uint256 amount,
        uint256 sqrt
    )
        external
        proposalActive(proposalIdToVoteFor)
        noVoteYetOnThisProposal(msg.sender, proposalIdToVoteFor)
        userStaked(msg.sender)
        userHasNoActiveProposal(msg.sender)
        joinedInTime(msg.sender)
        quadraticCorrect(amount, sqrt)
        isEligibleToVote(msg.sender)
    {
        _vote(proposalIdToVoteFor, msg.sender, amount, sqrt);
        emit VotedDirect(
            msg.sender,
            proposalIteration,
            proposalIdToVoteFor,
            amount,
            sqrt
        );
    }

    /// @dev Allows user proxy to vote on behalf of a user.
    /// @param proposalIdToVoteFor Id of the proposal they are voting for
    /// @param delegatedFrom user they are voting on behalf of
    function voteProxy(
        uint256 proposalIdToVoteFor,
        address delegatedFrom,
        uint256 amount,
        uint256 sqrt
    )
        external
        proposalActive(proposalIdToVoteFor)
        proxyRight(delegatedFrom)
        noVoteYetOnThisProposal(delegatedFrom, proposalIdToVoteFor)
        userStaked(delegatedFrom)
        userHasNoActiveProposal(delegatedFrom)
        joinedInTime(delegatedFrom)
        quadraticCorrect(amount, sqrt)
    {
        _isEligibleToVote(delegatedFrom);
        _vote(proposalIdToVoteFor, delegatedFrom, amount, sqrt);
        emit VotedViaProxy(
            msg.sender,
            delegatedFrom,
            proposalIteration,
            proposalIdToVoteFor,
            amount,
            sqrt
        );
    }

    /// @dev Internal function casting the actual vote from the requested address
    /// @param proposalIdToVoteFor Id of the proposal they are voting for
    /// @param voteAddress address the vote is stemming from
    function _vote(
        uint256 proposalIdToVoteFor,
        address voteAddress,
        uint256 amount,
        uint256 sqrt
    ) internal {
        _resetUsersVotingCreditIfFirstVoteThisIteration(voteAddress);
        hasUserVotedForProposalIteration[proposalIteration][voteAddress][proposalIdToVoteFor] = true;
        usersVoteCredit[proposalIteration][voteAddress] = usersVoteCredit[proposalIteration][voteAddress]
            .sub(amount); // SafeMath enforces they can't vote more then the credit they have.
        votesPerProposalForUser[proposalIteration][voteAddress][proposalIdToVoteFor] = sqrt;

        // Add the quadratic vote
        proposalVotes[proposalIteration][proposalIdToVoteFor] = proposalVotes[proposalIteration][proposalIdToVoteFor]
            .add(sqrt);


            uint256 topProjectVotes
         = proposalVotes[proposalIteration][topProject[proposalIteration]];

        // Currently, proposal getting to top vote first will win.
        // Keeps track of the top DAO this iteration.
        if (
            proposalVotes[proposalIteration][proposalIdToVoteFor] >
            topProjectVotes
        ) {
            topProject[proposalIteration] = proposalIdToVoteFor;
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////// Iteration changer / mining function  //////////////////////
    ///////////////////////////////////////////////////////////////////

    //// NOTE: Code commented out below is an experimental idea to award one voter from the previous iteration all the interest earned (as an incentive to vote).
    //         Ultimately we decided that it made sense to have a more "kickback" style distribution of interest to incentivise voting.
    // /**
    //  * @notice Requests randomness from a user-provided seed
    //  * @dev The user-provided seed is hashed with the current blockhash as an additional precaution.
    //  * @dev   1. In case of block re-orgs, the revealed answers will not be re-used again.
    //  * @dev   2. In case of predictable user-provided seeds, the seed is mixed with the less predictable blockhash.
    //  * @dev This is only an example implementation and not necessarily suitable for mainnet.
    //  * @dev You must review your implementation details with extreme care.
    //  */
    // function chooseRandomVotingWinner(uint256 userProvidedSeed)
    //     internal
    //     returns (bytes32 requestId)
    // {
    //     require(
    //         LINK.balanceOf(address(this)) > fee,
    //         "Not enough LINK - fill contract with faucet"
    //     );
    //     uint256 seed = uint256(
    //         keccak256(abi.encode(userProvidedSeed, blockhash(block.number)))
    //     ); // Hash user seed and blockhash
    //     bytes32 _requestId = requestRandomness(keyHash, fee, seed);
    //     return _requestId;
    // }

    // /**
    //  * @notice Callback function used by VRF Coordinator
    //  * @dev Important! Add a modifier to only allow this function to be called by the VRFCoordinator
    //  * @dev This is where you do something with randomness!
    //  * @dev The VRF Coordinator will only send this function verified responses.
    //  * @dev The VRF Coordinator will not pass randomness that could not be verified.
    //  */
    // function fulfillRandomness(bytes32 requestId, uint256 randomness)
    //     external
    //     override
    //     onlyVRFCoordinator
    // {
    //     uint256 d20Result = randomness.mod(20).add(1);

    //     depositContract.distributeInterest(
    //         interestReceivers,
    //         percentages,
    //         msg.sender, // change this to a random voter [chainlink VRF]
    //         proposalIteration
    //     );
    //     d20Results.push(d20Result);
    // }

    /// @dev Anyone can call this every 2 weeks (more specifically every *iteration interval*) to receive a reward, and increment onto the next iteration of voting
    function distributeFunds() external iterationElapsed {
        uint256 interestEarned = depositContract.interestAvailable();


            uint256 numberOfUserVotes
         = totalStakedVoteIncentiveInIteration[proposalIteration];

        if (numberOfUserVotes > 0) {
            totalIterationVotePayout[proposalIteration] = interestEarned;
        }

        proposalDeadline = now.add(votingInterval);
        proposalIteration = proposalIteration.add(1);

        emit IterationChanged(proposalIteration, msg.sender, now);
    }
}
