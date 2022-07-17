// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface NDCA {
    function totalDCA() external view returns (uint256);
    function pairListed(uint256 _dcaIndex) external view returns(address srcToken, uint256 srcDecimals, address destToken, uint256 destDecimals);
}

contract NDCA_V2 is Ownable {
    using SafeMath for uint256;
    using SafeMath for uint;
    
    struct pairStruct{
        address srcToken;
        uint256 srcDecimals;
        address destToken;
        uint256 destDecimals;
        mapping (address => userStruct) users;
        uint256 totalUsers;
        mapping (uint256 => address) usersList;
    }
    
    struct userStruct{
        uint256 srcAmount;
        uint256 tau;
        uint256 nextDcaTime;
        uint256 lastDcaTimeOk;
        uint256 destTokenEarned;
        uint averageBuyPrice;
        uint code;
        bool fundsTransfer;
    }
    //DCAs
    mapping (uint256 => pairStruct) neonDCAs;

    address constant nullAddress = 0x0000000000000000000000000000000000000000;

    address private neonRouter;
    address private swapper;
    uint256 private totalDCAs;
    uint256 private feePercent;
    uint256 private minTauLimit; //days
    uint256 private maxTauLimit; //days
    uint256 private minSrcAmount;
    bool private networkEnable;

    //Events
    event DCASwap(address indexed _receiver, address _srcToken, address _destToken, uint256 _destAmount, uint _status, uint256 _timestamp);
    event GetFunds(address indexed _sender, address _srcToken, uint256 _srcAmount, uint256 _timestamp);
    event Refund(address indexed _receiver, address _srcToken, uint256 _srcAmount, uint256 _timestamp);
    event CreatedDCA(address indexed _sender, uint256 _pairN, uint256 _srcAmount, uint256 _timestamp);
    event DeletedDCA(address indexed _sender, uint256 _pairN, uint256 _timestamp);

    /**
     * @dev Throws if called by any account other than the router.
     */
    modifier onlyRouter() {
        require(neonRouter != nullAddress, "NEON: Router not defined");
        require(msg.sender == neonRouter, "NEON: Only router is allowed");
        _;
    }
    /*
    * Constructor
    * () will be defined the unit of measure
    * @param _neonRouter address of the router
    * @param _minSrcAmount (ether) minimum amount of token to be invested
    * @param _feePercent fee (%) on the SrcToken
    * @param _minTauLimit (day) minimum time to be setted to exceute the DCA
    * @param _maxTauLimit (day) minimum time to be setted to exceute the DCA
    */
    constructor(address _neonRouter, address _swapper, uint256 _minSrcAmount, uint256 _feePercent, uint256 _minTauLimit, uint256 _maxTauLimit){
        neonRouter = _neonRouter;
        swapper = _swapper;
        minSrcAmount = _minSrcAmount;
        feePercent = _feePercent;
        minTauLimit = _minTauLimit;
        maxTauLimit = _maxTauLimit;
    }
    /*
    * @dev Enable Network
    */
    function setNetworkEnable() external onlyOwner {
        networkEnable = true;
    }
    /*
    * @dev Pause Network
    */
    function setNetworkPause() external onlyOwner {
        networkEnable = false;
    }
    /*
    * @dev define fee amount %
    * () will be defined the unit of measure
    * @param _percent (%) fee amount
    * @requirement > 0
    */
    function setFeeAmount(uint256 _percent) external onlyOwner {
        require(_percent > 0, "NEON: fee % must be > 0");
        feePercent = _percent;
    }
    /*
    * @dev Define router address
    * () will be defined the unit of measure
    * @param _account address
    * @requirement diff. 0x00
    */
    function setNeonRouter(address _account) external onlyOwner {
        require(_account != nullAddress, "NEON: nullAddress not allowed");
        neonRouter = _account;
    }
    /*
    * @dev Define swapper address
    * () will be defined the unit of measure
    * @param _account address
    * @requirement diff. 0x00
    */
    function setSwapper(address _account) external onlyOwner {
        require(_account != nullAddress, "NEON: nullAddress not allowed");
        swapper = _account;
    }
    /*
    * @dev Define min allow for time to execute dca
    * () will be defined the unit of measure
    * @param _value (day) time value
    */
    function setTauMinLimit(uint256 _value) external onlyOwner {
        minTauLimit = _value;
    }
    /*
    * @dev Define max allow for time to execute dca
    * () will be defined the unit of measure
    * @param _value (day) time value
    */
    function setTauMaxLimit(uint256 _value) external onlyOwner {
        require(_value > minTauLimit, "NEON: Max must be > Min");
        maxTauLimit = _value;
    }
    /*
    * @dev Define min amount to be invested
    * () will be defined the unit of measure
    * @param _value (ether) amount
    */
    function setMinAmount(uint256 _value) external onlyOwner {
        minSrcAmount = _value;
    }
    /* V1.1
    * @dev download pair list from another NDCA
    * () will be defined the unit of measure
    * @param _oldNDCA address of the old NDCA where pair list will be downloaded
    * @return bool successfully completed
    */
    function downloadPairList(address _oldNDCA) external onlyOwner returns(bool){
        NDCA pairPool = NDCA(_oldNDCA);
        require(networkEnable == false, "NEON: Network has to be disabled");
        uint256 poolTotalPairs = pairPool.totalDCA();
        uint256 i;
        for(i=1; i<=poolTotalPairs; i++){
            (address srcToken, uint256 srcDecimals, address destToken, uint256  destDecimals) = pairPool.pairListed(i);
            listNewPair(srcToken, srcDecimals, destToken, destDecimals);
        }
        return true;
    }
    /*
    * @dev List new pair ot token
    * () will be defined the unit of measure
    * @param _srcToken token to be invested
    * @param _srcDecimals token decimals
    * @param _destToken token to be recived
    * @param _destDecimals token decimals
    * @return bool successfully completed
    */
    function listNewPair(address _srcToken, uint256 _srcDecimals, address _destToken, uint256 _destDecimals) public onlyOwner returns(bool) {
        require(_srcToken != nullAddress && _destToken != nullAddress, "NEON: nullAddress not allowed");
        require(_srcToken != _destToken, "NEON: Source & Destination token must be different");
        uint256 i;
        bool error;
        for(i=1; i<=totalDCAs; i++){
            if(neonDCAs[i].srcToken == _srcToken && neonDCAs[i].destToken == _destToken){
                error = true;
                i = totalDCAs;
            }
        }
        require(error == false, "NEON: Token pair already listed");
        neonDCAs[totalDCAs + 1].srcToken = _srcToken;
        neonDCAs[totalDCAs + 1].destToken = _destToken;
        neonDCAs[totalDCAs + 1].srcDecimals = _srcDecimals;
        neonDCAs[totalDCAs + 1].destDecimals = _destDecimals;
        totalDCAs = totalDCAs.add(1);
        return true;
    }
    /*
    * @user Create DCA
    * !User must approve amount to this SC in order to create it!
    * () will be defined the unit of measure
    * @param _dcaIndex DCA where will create the DCA
    * @param _srcTokenAmount amount to be sell every tau
    * @param _tau time for each execution
    */ 
    function createDCA(uint256 _dcaIndex, uint256 _srcTokenAmount, uint256 _tau) external {
        require(networkEnable == true, "NEON: Network disabled");
        require(_dcaIndex > 0, "NEON: DCA index must be > 0");
        require(_srcTokenAmount > 0, "NEON: Amount must be > 0");
        require(_tau > 0, "NEON: Tau must be > 0");
        require(neonRouter != nullAddress, "NEON: Router not defined");

        require(_dcaIndex <= totalDCAs, "NEON: DCA index not listed");
        require(_tau >= minTauLimit && _tau <= maxTauLimit, "NEON: Tau out of limits");
        pairStruct storage dca = neonDCAs[_dcaIndex];
        uint256 minAmount = minSrcAmount * 10 ** dca.srcDecimals;
        require(_srcTokenAmount >= minAmount, "NEON: Amount too low");

        IERC20 srcToken = IERC20(dca.srcToken);

        require(dca.users[msg.sender].srcAmount == 0, "NEON: Already created DCA with this pair");
        require(srcToken.balanceOf(msg.sender) >= _srcTokenAmount, "NEON: Insufficient amount");
        uint256 preApprovalAmount = 15000000 * 10 ** dca.srcDecimals;
        require(srcToken.allowance(msg.sender, address(this)) >= preApprovalAmount,"NEON: Insufficient approved token");
        dca.users[msg.sender].srcAmount = _srcTokenAmount;
        dca.users[msg.sender].tau = _tau;
        uint256 tauSeconds = _tau.mul(24*60*60);
        dca.users[msg.sender].nextDcaTime = block.timestamp.add(tauSeconds);

        dca.totalUsers = dca.totalUsers.add(1);
        dca.usersList[dca.totalUsers] = msg.sender;

        emit CreatedDCA(msg.sender, _dcaIndex, _srcTokenAmount, block.timestamp);
    }
    /*
    * @user Delete DCA
    * () will be defined the unit of measure
    * @param _dcaIndex DCA where delete the DCA
    */ 
    function deleteDCA(uint256 _dcaIndex) external {
        require(_dcaIndex > 0, "NEON: DCA index must be > 0");
        require(_dcaIndex <= totalDCAs, "NEON: DCA index not listed");
        pairStruct storage dca = neonDCAs[_dcaIndex];
        uint256 i;
        uint256 userIndex = 0;
        for(i=1; i<=dca.totalUsers; i++){
            if(dca.usersList[i] == msg.sender){
                userIndex = i;
                i = dca.totalUsers;
            }
        }
        require(userIndex > 0, "NEON: DCA Already deleted");
        for(i=userIndex; i<=dca.totalUsers; i++){
            dca.usersList[i] = dca.usersList[i + 1];
        }
        dca.totalUsers = dca.totalUsers.sub(1);
        dca.users[msg.sender].srcAmount = 0;
        dca.users[msg.sender].tau = 0;
        dca.users[msg.sender].nextDcaTime = 0;
        dca.users[msg.sender].lastDcaTimeOk = 0;
        dca.users[msg.sender].destTokenEarned = 0;
        dca.users[msg.sender].averageBuyPrice = 0;
        dca.users[msg.sender].code = 0;
        dca.users[msg.sender].fundsTransfer = false;
        emit DeletedDCA(msg.sender, _dcaIndex, block.timestamp);
    }
    /*
    * @router Execute DCA
    * () will be defined the unit of measure
    * @param _dcaIndex DCA where router will execute
    * @param _userIndex user number to check/execute dca
    * @return bool state of execution
    */ 
    function routerExecuteDCA(uint256 _dcaIndex, uint256 _userIndex) external onlyRouter returns (bool){
        require(networkEnable == true, "NEON: Network disabled");
        require(_dcaIndex > 0, "NEON: DCA index must be > 0");
        require(_userIndex != 0, "NEON: User index must be > 0");
        require(_dcaIndex <= totalDCAs, "NEON: DCA index not listed");

        pairStruct storage dca = neonDCAs[_dcaIndex];
        require(_userIndex <= dca.totalUsers, "NEON: User index doesn't exist");
        IERC20 srcToken = IERC20(dca.srcToken);
        address currentUser = dca.usersList[_userIndex];
        require(block.timestamp >= dca.users[currentUser].nextDcaTime, "NEON: Execution not required yet");
        
        uint256 amount = dca.users[currentUser].srcAmount;
        require(srcToken.balanceOf(currentUser) >= amount, "NEON: Insufficient amount");
        require(srcToken.allowance(currentUser, address(this)) >= amount, "NEON: Insufficient approved token");
        if(dca.users[currentUser].fundsTransfer == false){
            dca.users[currentUser].fundsTransfer = true;
            require(srcToken.transferFrom(currentUser, neonRouter, amount), "NEON: Funds transfer error");
            emit GetFunds(currentUser, dca.srcToken, amount, block.timestamp);
        }
        return true;
    }
    /*
    * @router Result DCA
    * () will be defined the unit of measure
    * @param _dcaIndex DCA where router has executed
    * @param _userIndex user dca executed
    * @param _destTokenAmount amount user will recieve
    * @param _code integer to trace the DCA state of execution
    * @param _unitaryPrice unit purchase
    * @return bool state of execution
    */
    function routerResultDCA(uint256 _dcaIndex, uint256 _userIndex, uint256 _destTokenAmount, uint _code, uint _unitaryPrice) external onlyRouter returns (bool) {
        require(networkEnable == true, "NEON: Network disabled");
        require(_dcaIndex > 0, "NEON: DCA index must be > 0");
        require(_userIndex != 0, "NEON: User index must be > 0");
        require(_dcaIndex <= totalDCAs, "NEON: DCA index not listed");
        
        pairStruct storage dca = neonDCAs[_dcaIndex];
        require(_userIndex <= dca.totalUsers, "NEON: User index doesn't exist");
        IERC20 srcToken = IERC20(dca.srcToken);
        address currentUser = dca.usersList[_userIndex];
        require(block.timestamp >= dca.users[currentUser].nextDcaTime, "NEON: Execution not required yet");
        require(dca.users[currentUser].fundsTransfer == true, "NEON: Funds not claimed");
        uint256 amount = dca.users[currentUser].srcAmount;
        uint256 tau = dca.users[currentUser].tau;
        uint256 tauSeconds = tau.mul(24*60*60);
        dca.users[currentUser].nextDcaTime = dca.users[currentUser].nextDcaTime.add(tauSeconds);
        dca.users[currentUser].code = _code;
        if(_code == 200){
            dca.users[currentUser].fundsTransfer = false;
            dca.users[currentUser].lastDcaTimeOk = block.timestamp;
            dca.users[currentUser].destTokenEarned = dca.users[currentUser].destTokenEarned.add(_destTokenAmount);
            if(dca.users[currentUser].averageBuyPrice == 0){//only first time
                dca.users[currentUser].averageBuyPrice = _unitaryPrice;
            }else{
                dca.users[currentUser].averageBuyPrice = dca.users[currentUser].averageBuyPrice.add(_unitaryPrice).sub(2);//Average
            }
        }else{
            if(dca.users[currentUser].fundsTransfer == true){
                dca.users[currentUser].fundsTransfer = false;
                require(srcToken.transferFrom(neonRouter, currentUser, amount), "NEON: Refunds transfer error");
                emit Refund(currentUser, dca.srcToken, amount, block.timestamp);
            }
        }
        emit DCASwap(currentUser, dca.srcToken, dca.destToken, _destTokenAmount, _code, block.timestamp);
        return true;
    }
    /*
    * @view Total DCAs
    * () will be defined the unit of measure
    * @return uint256 total listed DCAs
    */
    function totalDCA() external view returns(uint256) {
        return totalDCAs;
    }
    /*
    * @view Network active
    * () will be defined the unit of measure
    * @return bool state of the network
    */
    function neonNetStatus() external view returns(bool) {
        return networkEnable;
    }
    /*
    * @view Total users into specific DCA
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @return uint256 number of total users
    */
    function totalUsers(uint256 _dcaIndex) external view returns(uint256) {
        return neonDCAs[_dcaIndex].totalUsers;
    }
    /*
    * @view Check if is router
    * () will be defined the unit of measure
    * @return true if the msg.sender is the router
    */
    function isRouter() external view returns(bool) {
        return (msg.sender == neonRouter);
    }
    /*
    * @view Check if is swapper
    * () will be defined the unit of measure
    * @return true if the msg.sender is the swapper
    */
    function isSwapper() external view returns(bool) {
        return (msg.sender == swapper);
    }
    /*
    * @view token listed address
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @return srcToken address source token
    * @return destToken address destination token
    */
    function pairListed(uint256 _dcaIndex) external view returns(address srcToken, uint256 srcDecimals, address destToken, uint256 destDecimals) {
        srcToken =  neonDCAs[_dcaIndex].srcToken;
        destToken =  neonDCAs[_dcaIndex].destToken;
        srcDecimals =  neonDCAs[_dcaIndex].srcDecimals;
        destDecimals =  neonDCAs[_dcaIndex].destDecimals;
    }
    /*
    * @view Check DCA to be execute
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @param _userIndex User number
    * @return bool enable execute
    */
    function routerCheckDCA(uint256 _dcaIndex, uint256 _userIndex) external view onlyRouter returns(bool) {
        pairStruct storage dca = neonDCAs[_dcaIndex];
        address currentUser = dca.usersList[_userIndex];
        require(currentUser != nullAddress, "NEON: User doesn't exist");
        require(dca.users[currentUser].srcAmount > 0, "NEON: Invalid amount");
        require(dca.users[currentUser].nextDcaTime > 0, "NEON: Invalid execute time");
        uint256 nextDcaTime = dca.users[currentUser].nextDcaTime;
        return block.timestamp >= nextDcaTime;
    }
    /*
    * @view Check user available amount
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @param _userIndex User number
    * @return bool enable execute
    */
    function routerCheckAmount(uint256 _dcaIndex, uint256 _userIndex) external view onlyRouter returns(bool) {
        pairStruct storage dca = neonDCAs[_dcaIndex];
        address currentUser = dca.usersList[_userIndex];
        require(currentUser != nullAddress, "NEON: User doesn't exist");
        require(dca.users[currentUser].srcAmount > 0, "NEON: Invalid amount");
        require(dca.users[currentUser].nextDcaTime > 0, "NEON: Invalid execute time");
        IERC20 srcToken = IERC20(dca.srcToken);
        return srcToken.balanceOf(currentUser) >= dca.users[currentUser].srcAmount;
    }
    /*
    * @view Router info to execute DCA
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @param _userIndex User number
    * @return srcToken address of the token
    * @return srcDecimals number of decimals
    * @return destToken address of the token
    * @return destDecimals number of decimals
    * @return reciever address user for DCA
    * @return srcTokenAmount amount to be swap
    */
    function routerUserInfo(uint256 _dcaIndex, uint256 _userIndex) external view onlyRouter returns(
        address srcToken,
        uint256 srcDecimals,
        address destToken,
        uint256 destDecimals,
        address reciever,
        uint256 srcTokenAmount
    )
    {
        pairStruct storage dca = neonDCAs[_dcaIndex];
        address currentUser = dca.usersList[_userIndex];
        uint256 feeAmount = dca.users[currentUser].srcAmount.div(100).mul(feePercent);

        srcToken = dca.srcToken;
        srcDecimals = dca.srcDecimals;
        destToken = dca.destToken;
        destDecimals = dca.destDecimals;
        reciever = currentUser;
        srcTokenAmount = dca.users[currentUser].srcAmount.sub(feeAmount);
    }
    /*
    * @view Dashboard info for the user
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @return dcaActive DCA active
    * @return srcTokenAmount Amount invested for each DCA
    * @return tau frequency of execution
    * @return nextDcaTime time next DCA execution
    * @return lastDcaTimeOk time last DCA executed with success
    * @return destTokenEarned total token bought since DCA creation
    * @return averageBuyPrice unit purchase average
    * @return code code of last execution DCA
    */
    function dashboardUser(uint256 _dcaIndex) external view returns(
        bool dcaActive,
        uint256 srcTokenAmount,
        uint256 tau,
        uint256 nextDcaTime,
        uint256 lastDcaTimeOk,
        uint256 destTokenEarned,
        uint averageBuyPrice,
        uint code
    ) 
    {
        pairStruct storage dca = neonDCAs[_dcaIndex];
        if(dca.users[msg.sender].srcAmount > 0){
            dcaActive = true;
            srcTokenAmount = dca.users[msg.sender].srcAmount;
            tau = dca.users[msg.sender].tau;
            nextDcaTime = dca.users[msg.sender].nextDcaTime;
            lastDcaTimeOk = dca.users[msg.sender].lastDcaTimeOk;
            destTokenEarned = dca.users[msg.sender].destTokenEarned;
            averageBuyPrice = dca.users[msg.sender].averageBuyPrice;
            code = dca.users[msg.sender].code;
        }else{
            dcaActive = false;
        }
    }
    /*
    * @view available/approved token for NEON
    * () will be defined the unit of measure
    * @param _dcaIndex DCA number
    * @return amountSC Amount approved token for DCAs (this contract) from Neon Router
    * @return amountSwapper Amount approved token for Swapper from Neon Router
    */
    function availableTokens(uint256 _dcaIndex) external view returns(uint256 amountSC, uint256 amountSwapper) {
        pairStruct storage dca = neonDCAs[_dcaIndex];
        IERC20 srcToken = IERC20(dca.srcToken);
        amountSC = srcToken.allowance(neonRouter, address(this));
        amountSwapper = srcToken.allowance(neonRouter, swapper);
    }
}