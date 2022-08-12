//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Crowdsale is Context, ReentrancyGuard {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        bool initialized;
        
        address  beneficiary;

        uint256  cliff;

        uint256  start;

        uint256  duration;

        uint256 slicePeriodSeconds;

        bool  revocable;

        uint256 amountTotal;

        uint256  released;

        bool revoked;
    }

    uint256 public _rate;

    address payable _wallet;

    address _admin;

    IERC20 public _token;

    uint256 public _weiRaised;

    uint256 public _tokensSold;

    bool public timestampSet;

    uint256 startTime = 0;

    uint256 internal _durationVesting;

    uint256 internal _periodVesting;

    uint256 internal _cliffVesting;

    bytes32[] internal vestingSchedulesIds;
    
    mapping(bytes32 => VestingSchedule) internal vestingSchedules;
    
    uint256 internal vestingSchedulesTotalAmount;
    
    mapping(address => uint256) internal holdersVestingCount;

    mapping(address => uint256) internal _contribution;

    mapping(address => uint256) public withdrawnTokens;

    mapping(address => uint256) public frozenTokens;

    event TokenPurchased(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);

    event TokenReleased(address indexed beneficiary, uint256 value);
    
    event WithdrawBNB(address indexed admin, uint256 value);
    
    event PresaleEnded(address indexed admin, uint256 value);

    AggregatorV3Interface internal priceFeed;

    modifier onlyAdmin() {
        require(_admin == _msgSender(), "Called from non admin wallet");
        _;
    }

    modifier minAmount() {
        require(_getMinimalAmount(msg.value) >= 10,"Minimal amount is $10");
        _;
    }

    modifier timestampNotSet() {
        require(timestampSet == false, "The time stamp has already been set.");
        _;
    }
    
    modifier timestampIsSet() {
        require(timestampSet == true, "Please set the time stamp first, then try again.");
        _;
    }

    modifier onlyIfVestingScheduleExists(bytes32 vestingScheduleId) {
        require(vestingSchedules[vestingScheduleId].initialized == true);
        _;
    }

    modifier onlyIfVestingScheduleNotRevoked(bytes32 vestingScheduleId) {
        require(vestingSchedules[vestingScheduleId].initialized == true);
        require(vestingSchedules[vestingScheduleId].revoked == false);
        _;
    }
    

    constructor(IERC20 token, address payable wallet, uint256 rate) {
        _token = token;
        _wallet = wallet;
        _admin = _msgSender();
        _rate = rate;

        priceFeed = AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);

        timestampSet = false;

        _durationVesting = 15552000; //- 180days in seconds
        _periodVesting = 604800; //- 7 days in seconds
        _cliffVesting = 0;
    }

    fallback() external payable {
        buyTokens(_msgSender());
    }

    function buyTokens(address beneficiary) public payable minAmount nonReentrant {
        uint256 weiAmount = msg.value;

        _prevalidatePurchase(beneficiary, weiAmount);

        uint256 tokenAmount = _getTokenAmount(weiAmount);

        _weiRaised = _weiRaised.add(weiAmount);

        _tokensSold += tokenAmount;

        _updateContribution(beneficiary, weiAmount);

        uint256 currentTime = getCurrentTime();

        createVestingSchedule(beneficiary, currentTime, _cliffVesting, _durationVesting, _periodVesting, true, tokenAmount);

        emit TokenPurchased(_msgSender(), beneficiary, weiAmount, tokenAmount);
    }

    function _getMinimalAmount(uint256 weiAmount) internal view returns (uint256){
        int bnbPrice = _getBNBPrice();

        uint256 _bnbPrice = uint256(bnbPrice);
        uint256 _Amount = ((weiAmount*(_bnbPrice*10**10))/(10**18))/(10**18);

        return _Amount;   
    }

    function getTokenPrice() public view returns (uint256) {
        return _getTokenAmount(1*10**8);
    }

    function _getBNBPrice() internal view returns (int) {
        (
            , 
            int price,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        return price;
    }

    function _getTokenAmount(uint256 weiAmount) internal view returns(uint256) {
        int bnbPrice = _getBNBPrice();

        uint256 _bnbPrice = uint256(bnbPrice);

        uint256 _Amount = _bnbPrice/_rate;

        return weiAmount.mul(_Amount);
    }

    function _forwardFunds(uint256 weiAmount) internal {
        _wallet.transfer(weiAmount); 
    }

    function _updateContribution(address beneficiary, uint256 weiAmount) internal {
        _contribution[beneficiary] += weiAmount;
    }

    function _processPurchase(address beneficiary, uint256 tokenAmount) internal {
        _token.safeTransfer(beneficiary, tokenAmount);
    }

    function _prevalidatePurchase(address beneficiary, uint256 weiAmount) internal view {
        require(beneficiary != address(0), "Beneficiary is zero address");
        require(weiAmount != 0, "Wei amount is zero");
        this;
    }

    function withdrawFunds() public onlyAdmin {
        uint256 weiAmount = address(this).balance;

        _forwardFunds(address(this).balance); 

        emit WithdrawBNB(_msgSender(), weiAmount);
    }

    function getVestingSchedulesCountByBeneficiary(address _beneficiary) external view returns(uint256) {
        return holdersVestingCount[_beneficiary];
    }

    function getVestingIdAtIndex(uint256 index) external view returns(bytes32) {
        require(index < getVestingSchedulesCount(), "Index out of bounds");
        return vestingSchedulesIds[index];
    }

    function getVestingScheduleByAddressAndIndex(address holder, uint256 index) external view returns(VestingSchedule memory) {
        return getVestingSchedule(computeVestingScheduleIdForAddressAndIndex(holder, index));
    }

    function getVestingSchedulesTotalAmount() external view returns(uint256) {
        return vestingSchedulesTotalAmount;
    }

    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool _revocable,
        uint256 _amount
    )
        internal 
    {
        require(
            getWithdrawableAmount() >= _amount,
            "Cannot create vesting schedule because not sufficient tokens"
        );
        require(_duration > 0, "Duration must be > 0");
        require(_amount > 0, "Amount must be > 0");
        require(_slicePeriodSeconds >= 1, "SlicePeriodSeconds must be >= 1");
        bytes32 vestingScheduleId = computeNextVestingScheduleIdForHolder(_beneficiary);
        uint256 cliff = _start.add(_cliff);
        vestingSchedules[vestingScheduleId] = VestingSchedule(
            true,
            _beneficiary,
            cliff,
            _start,
            _duration,
            _slicePeriodSeconds,
            _revocable,
            _amount,
            0,
            false
        );
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount.add(_amount);
        vestingSchedulesIds.push(vestingScheduleId);
        uint256 currentVestingCount = holdersVestingCount[_beneficiary];
        holdersVestingCount[_beneficiary] = currentVestingCount.add(1);
        frozenTokens[_beneficiary] = frozenTokens[_beneficiary].add(_amount);
    }
    
    function revoke(bytes32 vestingScheduleId) public onlyAdmin onlyIfVestingScheduleNotRevoked(vestingScheduleId) {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        require(vestingSchedule.revocable == true, "Vesting is not revocable");
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        if(vestedAmount > 0){
            release(vestingScheduleId, vestedAmount);
        }
        uint256 unreleased = vestingSchedule.amountTotal.sub(vestingSchedule.released);
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount.sub(unreleased);
        vestingSchedule.revoked = true;
    }

    function withdrawRemainderTokens(uint256 amount) public nonReentrant onlyAdmin {
        require(getWithdrawableAmount() >= amount, "Not enough withdrawable funds");
        _token.safeTransfer(_admin, amount);
    }

    function release(
        bytes32 vestingScheduleId,
        uint256 amount
    ) public nonReentrant timestampIsSet onlyIfVestingScheduleNotRevoked(vestingScheduleId) {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        bool isBeneficiary = msg.sender == vestingSchedule.beneficiary;
        bool isOwner = msg.sender == _admin;
        require(
            isBeneficiary || isOwner,
            "Only beneficiary and owner can release vested tokens"
        );
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        require(vestedAmount >= amount, "Cannot release tokens, not enough vested tokens");
        vestingSchedule.released = vestingSchedule.released.add(amount);
        withdrawnTokens[vestingSchedule.beneficiary] = withdrawnTokens[vestingSchedule.beneficiary].add(amount);
        address payable beneficiaryPayable = payable(vestingSchedule.beneficiary);
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount.sub(amount);
        _token.safeTransfer(beneficiaryPayable, amount);
        emit TokenReleased(beneficiaryPayable, amount);
    }

    function getVestingSchedulesCount() public view returns(uint256){
        return vestingSchedulesIds.length;
    }

    function computeReleasableAmount(bytes32 vestingScheduleId)
        public
        onlyIfVestingScheduleNotRevoked(vestingScheduleId)
        view
        returns(uint256){
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        return _computeReleasableAmount(vestingSchedule);
    }

    function getVestingSchedule(bytes32 vestingScheduleId) public view returns(VestingSchedule memory){
        return vestingSchedules[vestingScheduleId];
    }


    function getWithdrawableAmount() public view returns(uint256){
        return _token.balanceOf(address(this)).sub(vestingSchedulesTotalAmount);
    }

    function computeNextVestingScheduleIdForHolder(address holder) public view returns(bytes32) {
        return computeVestingScheduleIdForAddressAndIndex(holder, holdersVestingCount[holder]);
    }


        
    function computeVestingScheduleIdForAddressAndIndex(address holder, uint256 index)
        public
        pure
        returns(bytes32){
        return keccak256(abi.encodePacked(holder, index));
    }

    function _computeReleasableAmount(VestingSchedule memory vestingSchedule) internal view returns(uint256){
        uint256 currentTime = getCurrentTime();

        uint256 startVestingTime = vestingSchedule.start.add(startTime);

        if ((currentTime < vestingSchedule.cliff) || vestingSchedule.revoked == true) {
            return 0;
        } else if (currentTime >= startVestingTime.add(vestingSchedule.duration)) {
            return vestingSchedule.amountTotal.sub(vestingSchedule.released);
        } else {
            uint256 timeFromStart = currentTime.sub(startVestingTime);
            uint secondsPerSlice = vestingSchedule.slicePeriodSeconds;
            uint256 vestedSlicePeriods = timeFromStart.div(secondsPerSlice);
            uint256 vestedSeconds = vestedSlicePeriods.mul(secondsPerSlice);
            uint256 vestedAmount = vestingSchedule.amountTotal.mul(vestedSeconds).div(vestingSchedule.duration);
            vestedAmount = vestedAmount.sub(vestingSchedule.released);
            return vestedAmount;
        }
    }

    function setCurrentTime(uint256 _time) external onlyAdmin timestampNotSet {
        timestampSet = true;
        startTime = _time; //time difference between first deposit and current time in seconds
    }

    function getCurrentTime() internal virtual view returns(uint256){
        return block.timestamp;
    }
} 