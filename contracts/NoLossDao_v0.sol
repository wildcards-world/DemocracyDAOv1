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
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public hasUserVotedForProposalIteration; /// iteration -> userAddress -> proposalId -> bool
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public votesPerProposalForUser; // iteration -> user -> chosen project -> votes
    mapping(uint256 => mapping(address => uint256)) public usersVoteCredit; // iteration -> address -> credit

    //////// DAO / VOTE specific //////////
    mapping(uint256 => mapping(uint256 => uint256)) public proposalVotes; /// iteration -> proposalId -> num votes
    mapping(uint256 => uint256) public topProject;
    mapping(address => address) public voteDelegations; // For vote proxy

    //////// Necessary to fund dev and miners //////////
    address[] interestReceivers; // in v0, the interestReceivers is the address of the miner.
    uint256[] percentages;

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
        proposalDeadline = now.add(_votingInterval);
        interestReceivers.push(admin); // This will change to miner when iterationchanges
        percentages.push(50); // 5% for miner

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

    /// @dev Changes the amount required to stake for new proposal
    function setInterestReceivers(
        address[] memory _interestReceivers,
        uint256[] memory _percentages
    ) public onlyAdmin {
        require(
            _interestReceivers.length == _percentages.length,
            "Arrays should be equal length"
        );
        uint256 percentagesSum = 0;
        for (uint256 i = 0; i < _percentages.length; i++) {
            percentagesSum = percentagesSum.add(_percentages[i]);
        }
        require(percentagesSum < 1000, "Percentages total too high");

        interestReceivers = _interestReceivers;
        percentages = _percentages;
        emit InterestConfigChanged(
            _interestReceivers,
            _percentages,
            proposalIteration
        );
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////// Deposit & withdraw function for users //////////
    ////////and proposal holders (benefactors) /////////////
    ////////////////////////////////////////////////////////

    /// @dev Checks whether user is eligible deposit and sets the proposal iteration joined, to the current iteration
    /// @param userAddress address of the user wanting to deposit
    /// @return boolean whether the above executes successfully
    function noLossDeposit(address userAddress, uint256 amount)
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
            usersVoteCredit[proposalIteration][givenAddress] = depositContract
                .usersVotingCredit(givenAddress);
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
        userVotedThisIteration[proposalIteration][voteAddress] = true;
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

    /// @dev Anyone can call this every 2 weeks (more specifically every *iteration interval*) to receive a reward, and increment onto the next iteration of voting
    function distributeFunds() external iterationElapsed {
        interestReceivers[0] = msg.sender; // Set the miners address to receive a small reward

        // To incetivize voting and joining the DAO, like a simply poolTogether, you could win the DAO's interest...
        depositContract.distributeInterest(
            interestReceivers,
            percentages,
            msg.sender, // change this to a random voter [chainlink VRF]
            proposalIteration
        );

        proposalDeadline = now.add(votingInterval);
        proposalIteration = proposalIteration.add(1);

        emit IterationChanged(proposalIteration, msg.sender, now);
    }
}
