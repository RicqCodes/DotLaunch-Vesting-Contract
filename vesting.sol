pragma solidity 0.8.11;

//SPDX-License-Identifier: Apache-2.0

/**
* @title TOKENVESTING FOR DOTLAUNCH 
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract  TokenVesting is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    struct VestingPlan {

        address beneficiary; // address of Beneficiary that would receive token upon unlocking.
        uint cliff; // Total CLiff period in seconds.
        uint start; // duration of the vesting period in seconds.
        uint length; // length/duration of the vesting period in seconds.
        uint slicePeriodSeconds; // duration of a slice period for the vesting in seconds
        bool initialized; //whether or not vesting is ongoing;
        bool revocable; //whether or not the vesting is revocable;
        uint amountToken; // amount of tokens released;
        uint released; // amount of tokens released;
        bool revoked; // wheether or not the vesting has been revoked;

    }
        //contract address of the ERC20 token

        IERC20 immutable private _token;


        event released(uint amount);
        event revoked();

        bytes32[] private vestingPlanIds;
        mapping(bytes32 => VestingPlan) private vestingPlans;
        uint private vestingPlanTotalAmount;
        mapping(address => uint) private holdersVestingCount;


        /**
        * @dev Reverts if no vesting plan matches the identifier passed
        */
        modifier vestingPlanExists(bytes32 vestingPlanId) {
            require(vestingPlans[vestingPlanId].initialized == true);
            _;
        }
        /**
        * @dev Reverts if the vesting plan does not exist or has already been revoked
         */
        modifier vestingPlanNotRevoked(bytes32 vestingPlanId) {
            require(vestingPlans[vestingPlanId].initialized == true);
            require(vestingPlans[vestingPlanId].revoked == false);
            _;
        }

        /**
        * @dev Creates a vesting contract.
        * @param token address of the ERC20 token contract
        */
         constructor(address token) {
             require(token != address(0x0));
             _token = IERC20(token);
         }

         receive() external payable {}

         fallback() external payable {}

         /** 
         *  @dev returns the number of vesting plans schedules associated to a beneficiary.
         *  @return the number of vesting schedules 
         */

         function getVestingPlansCountByBeneficiary(address _beneficiary) external view returns(uint) {
             return holdersVestingCount[_beneficiary];
         }

        /**
        * @dev returns the vesting schedule id at the gien index
        * @return the vesting id
        */
        function getVestingIdAtIndex(uint _index) external view returns(bytes32) {
            require(_index < getVestingPlanCount(), "DOTLAUNCH TokenVesting:index out of bounds!");
            return vestingPlanIds[_index];
        }

        /** 
        * @notice returns the vesting plan information for a given holder and index
        * @return the vesting plan structure information
        */
        function getVestingPlanByAddressAndIndex(address _holder, uint index) external view returns(VestingPlan memory) {
            return getVestingPlan(computeVestingPlanIdForAddressAndIndex(_holder, index));
        }

        /** 
        * @notice returns the total amount of vesting plans.
        @return the total amount of vesting plans 
        */
        function getVestingPlansTotalAmount() external view returns(uint) {
            return vestingPlanTotalAmount;
        }

    /** 
    * @dev returns the address of ERC20 token been managed by the vesting contract
    */
    function  getToken() external view returns(address) {
        return address(_token);
    }

/**
* @notice Creates a new vesting plan for a beneficiary
* @param _beneficiary: addres of the beneficiary to whom vested tokens are released to
* @param _start time of the vesting period
* @param _cliff duration in seconds of the cliff in which tokens will begin to vest
* @param _slicePeriodSeconds duration of a slice period for the vesting in seconds
* @param _revocable whether the vesting is revocable or not
* @param _amount total amount of tokens to be released at the end of the vesting
* @param _length duration in seconds of the period in which the tokens will vest
*/

function createVestingPlan(address _beneficiary, uint _start, uint _cliff, uint _slicePeriodSeconds, bool _revocable, uint _amount, uint _length) public onlyOwner {
    require(this.getWithdrawableAmount() >= _amount, "DOTLAUNCH TokenVesting: you cannot create vesting plan because not sufficient tokens");
    require(_amount > 0, "DOTLAUNCH TokenVesting: amount must be greater than 0");
    require(_slicePeriodSeconds >= 1, "DOTLAUNCH TokenVesting: slicePeriodSeconds must be greater than or equal to 1");
    require(_length > 0, "DOTLAUNCH TokenVesting: duration must be greater 0");
    bytes32 vestingPlanId = this.computeNextVestingPlanIdForHolder(_beneficiary);
    uint cliff = _start.add(_cliff);
    vestingPlans[vestingPlanId] = VestingPlan(_beneficiary, cliff, _start, _length, _slicePeriodSeconds, true, _revocable, _amount, 0, false);
    vestingPlanTotalAmount = vestingPlanTotalAmount.add(_amount);
    vestingPlanIds.push(vestingPlanId);
    uint currentVestingCount = holdersVestingCount[_beneficiary];
    holdersVestingCount[_beneficiary] = currentVestingCount.add(1);
}

/** 
* @notice revokes the vesting plan for given identifier
* @param vestingPlanId the vesting plan identifier
*/

    function revoke(bytes32 vestingPlanId) public onlyOwner vestingPlanNotRevoked(vestingPlanId){
        VestingPlan storage vestingPlan = vestingPlans[vestingPlanId];
        require(vestingPlan.revocable == true, "DOTLAUNCH TokenVesting: vesting is not revocable");
        uint256 vestedAmount = _computeReleasableAmount(vestingPlan);
        if(vestedAmount > 0){
            release(vestingPlanId, vestedAmount);
        }
        uint unreleased = vestingPlan.amountToken.sub(vestingPlan.released);
        vestingPlanTotalAmount = vestingPlanTotalAmount.sub(unreleased);
        emit revoked();
        vestingPlan.revoked = true;
}

    /**
    * @notice Withdraw the specified amount if possible.
    * @param amount the amount to withdraw
    */

    function withdraw(uint amount) public nonReentrant onlyOwner{
        require(this.getWithdrawableAmount() >= amount, "DOTLAUNCH TokenVesting: not enough withdrawable fnds ");
        _token.safeTransfer(owner(), amount);
    }

    function release(bytes32 vestingPlanId, uint amount) public nonReentrant vestingPlanNotRevoked(vestingPlanId) {
        VestingPlan storage vestingPlan = vestingPlans[vestingPlanId];
        bool isBeneficiary =  msg.sender == vestingPlan.beneficiary;
        bool isOwner =  msg.sender == owner();
        require(isBeneficiary || isOwner, "DOTLAUNCH TokenVesting: only beneficiary or owner can release vested tokens");
    
        uint vestedAmount = _computeReleasableAmount(vestingPlan);
        require(vestedAmount >= amount, "DOTLAUNCH TokenVesting: cannot release tokens, there are not enough vested tokens");
        vestingPlan.released = vestingPlan.released.add(amount);
        address beneficiary = (vestingPlan.beneficiary);
        vestingPlanTotalAmount = vestingPlanTotalAmount.sub(amount);
        emit released(amount);
        _token.safeTransfer(beneficiary, amount);
    }

    /**
    * @dev Returns the number of vesting Plan that are managed by this contract.
    * @return the number of vesting Plan
    */
    function getVestingPlanCount() public view returns(uint256) {
        return vestingPlanIds.length;
    }

    /**
    * @notice calculates the vested amount of tokens for the given vesting plan identifier.
    * @return the vested amount
    */
    function computeReleasableAmount(bytes32 vestingPlanId) public vestingPlanNotRevoked(vestingPlanId) view returns(uint256) {
        VestingPlan storage vestingPlan = vestingPlans[vestingPlanId];
        return _computeReleasableAmount(vestingPlan);
    }

    /**
    * @notice Returns the vesting schedule information for a given identifier.
    * @return the vesting schedule structure information
    */
    function getVestingPlan(bytes32 vestingPlanId)
        public
        view
        returns(VestingPlan memory){
        return vestingPlans[vestingPlanId];
    }

    /**
    * @dev Returns the amount of tokens that can be withdrawn by the owner.
    * @return the amount of tokens
    */
    function getWithdrawableAmount() public view returns(uint256){
        return _token.balanceOf(address(this)).sub(vestingPlanTotalAmount);
    }

    /**
    * @dev Computes the next vesting schedule identifier for a given holder address.
    */
    function computeNextVestingPlanIdForHolder(address holder)
        public
        view
        returns(bytes32){
        return computeVestingPlanIdForAddressAndIndex(holder, holdersVestingCount[holder]);
    }

    /**
    * @dev Returns the last vesting Plan for a given holder address.
    */
    function getLastVestingScheduleForHolder(address holder)
        public
        view
        returns(VestingPlan memory){
        return vestingPlans[computeVestingPlanIdForAddressAndIndex(holder, holdersVestingCount[holder] - 1)];
    }

    /**
    * @dev Computes the vesting schedule identifier for an address and an index.
    */
    function computeVestingPlanIdForAddressAndIndex(address holder, uint256 index)
        public
        pure
        returns(bytes32){
        return keccak256(abi.encodePacked(holder, index));
    }

    /**
    * @dev Computes the releasable amount of tokens for a vesting plan.
    * @return the amount of releasable tokens
    */
    function _computeReleasableAmount(VestingPlan memory vestingPlan) internal view returns(uint256){
        uint256 currentTime = getCurrentTime();
        if ((currentTime < vestingPlan.cliff) || vestingPlan.revoked == true) {
            return 0;
        } else if (currentTime >= vestingPlan.start.add(vestingPlan.length)) {
            return vestingPlan.amountToken.sub(vestingPlan.released);
        } else {
            uint256 timeFromStart = currentTime.sub(vestingPlan.start);
            uint secondsPerSlice = vestingPlan.slicePeriodSeconds;
            uint256 vestedSlicePeriods = timeFromStart.div(secondsPerSlice);
            uint256 vestedSeconds = vestedSlicePeriods.mul(secondsPerSlice);
            uint256 vestedAmount = vestingPlan.amountToken.mul(vestedSeconds).div(vestingPlan.length);
            vestedAmount = vestedAmount.sub(vestingPlan.released);
            return vestedAmount;
        }
    }

    function getCurrentTime()
        internal
        virtual
        view
        returns(uint256){
        return block.timestamp;
    }

}

