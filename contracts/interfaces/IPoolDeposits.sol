pragma solidity ^0.5.0;


contract IPoolDeposits {
    mapping(address => uint256) public depositedDai;

    function usersVotingCreditAndVoteIncentiveState(address user)
        external
        view
        returns (uint256, uint256)
    {}

    function usersDeposit(address userAddress) external view returns (uint256);

    function changeProposalAmount(uint256 amount) external;

    function redirectInterestStreamToWinner(address _winner) external;

    function interestAvailable() external view returns (uint256 amountToRedeem);

    function payoutVotingIncentive(address voter, uint256 payoutAmount)
        external;
}
