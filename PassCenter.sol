// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";



interface IPassCenter {
    function baseURI() external view returns (string memory);
    function notifyTransfer(address from, address to, uint256 tokenId) external;
}



contract Pass is ERC721Enumerable, Ownable {

    /**
     * Variable
     */

    IPassCenter public passCenter;

    /**
     * Constructor
     */

    constructor(
        address _passCenter,
        address _owner,
        string memory _name,
        string memory _symbol
    ) ERC721(_name, _symbol) {

        _transferOwnership(_owner);
        passCenter = IPassCenter(_passCenter);
    }


    /**
     * Pass
     */

    modifier onlyPassCenter() {
        require(_msgSender() == address(passCenter), "Pass: Illegal msgSender");
        _;
    }

    function _baseURI() internal view override returns (string memory) {

        return string(abi.encodePacked(
            passCenter.baseURI(),
            Strings.toHexString(uint256(uint160(address(this))), 20),
            "/"
        ));
    }

    function mint(address to, uint256 tokenId) public onlyPassCenter {
        _mint(to, tokenId);
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {

        passCenter.notifyTransfer(from, to, tokenId);
    }
}



contract PassCenter is Initializable, PausableUpgradeable, AccessControlUpgradeable, IPassCenter {

    /**
     * Library
     */

    using CountersUpgradeable for CountersUpgradeable.Counter;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;


    /**
     * Struct
     */

    struct PassInfo {
        string coverURI;
        string name;
        string domain;
        uint256 claimPrice;
        uint256 renewalPrice;
        uint256 validityPeriod;
        address feeReceiver;
    }

    struct PassTokenInfo {
        string coverURI;
        string name;
        string domain;

        uint256 expiredAt;
    }

    struct PassProperty {
        uint256 totalSupply;
        uint16 feeRatioPermillage;
        CountersUpgradeable.Counter tokenIdTracker;

        PassInfo info;
        string[] records;

        mapping(uint256 => PassTokenInfo) tokenInfo;
        mapping(uint256 => string[]) tokenRecords;
    }


    /**
     * Variable
     */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");

    address public feeReceiver;
    uint16 public baseFeeRatioPermillage;

    string private passBaseURI;
    EnumerableSetUpgradeable.AddressSet private passes;
    mapping(address => PassProperty) private passProperty;


    /**
     * Event
     */

    event ParameterSet(string baseURI, address feeReceiver, uint16 baseFeeRatioPermillage);

    event PassCreated(address indexed issuer, address indexed pass);
    event PassFeeSet(address indexed pass, uint16 feeRatioPermillage);
    event PassInfoSet(address indexed pass, PassInfo info);
    event PassRecordAdded(address indexed pass, string record);

    event PassTokenMinted(address indexed pass, uint256 supply);
    event PassTokenRecordAdded(address indexed pass, uint256 indexed tokenId, string record);
    event PassTokenClaimed(address indexed pass, uint256 indexed tokenId, PassTokenInfo info, address feeReceiver, uint256 feeAmount);
    event PassTokenRenewed(address indexed pass, uint256 indexed tokenId, uint256 expiredAt, address feeReceiver, uint256 feeAmount);
    event PassTokenTransfer(address indexed pass, uint256 indexed tokenId, address from, address to);


    /**
     * Initializer
     */

    function initialize(string memory _baseURI, address _feeReceiver, uint16 _feeRatio) public initializer {

        __Pausable_init();
        __AccessControl_init();

        _grantRole(PAUSER_ROLE, _msgSender());
        _grantRole(MAINTAINER_ROLE, _msgSender());
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        setParameter(_baseURI, _feeReceiver, _feeRatio);
    }


    /**
     * Pausable
     */

    function puase() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }


    /**
     * IPassCenter
     */

    function baseURI() external view override returns (string memory) {
        return passBaseURI;
    }

    function notifyTransfer(address from, address to, uint256 tokenId)
        external override checkPass(_msgSender()) {

        emit PassTokenTransfer(_msgSender(), tokenId, from, to);
    }


    /**
     * PassCenter
     */

    function setParameter(
        string memory _baseURI,
        address _feeReceiver,
        uint16 _feeRatio
    ) public onlyRole(MAINTAINER_ROLE) whenNotPaused {

        require(_feeRatio < 1000, "PassCenter: Illegal feeRatioPermillage");

        passBaseURI = _baseURI;
        feeReceiver = _feeReceiver;
        baseFeeRatioPermillage = _feeRatio;

        emit ParameterSet(passBaseURI, feeReceiver, baseFeeRatioPermillage);
    }


    /**
     * Pass
     */

    modifier checkPass(address pass) {
        require(passes.contains(pass), "PassCenter: Illegal pass");
        _;
    }

    modifier checkPassOwner(address pass, address addr) {
        require(Pass(pass).owner() == addr, "PassCenter: Illegal passOwner");
        _;
    }

    function listPasses() public view returns (address[] memory) {
        return passes.values();
    }

    function createPass(uint256 _supply, PassInfo memory _info) public whenNotPaused {

        require(_supply > 0, "PassCenter: Illegal supply");

        address issuer = _msgSender();
        address pass = address(new Pass(address(this), issuer, "Pass", "PASS"));

        emit PassCreated(issuer, pass);

        passes.add(pass);

        _setPassInfo(pass, _info);
        _setPassFee(pass, baseFeeRatioPermillage);

        _mintPassToken(pass, _supply);
    }

    function setPassesFee(address[] memory _passes, uint16 _feeRatio)
        public whenNotPaused onlyRole(MAINTAINER_ROLE) {

        for (uint i = 0; i < _passes.length; i++) {
            require(passes.contains(_passes[i]), "PassCenter: Illegal passes");
        }

        for (uint i = 0; i < _passes.length; i++) {
            _setPassFee(_passes[i], _feeRatio);
        }
    }

    function _setPassFee(address pass, uint16 _feeRatio) internal {

        require(_feeRatio < 1000, "PassCenter: Illegal feeRatioPermillage");

        passProperty[pass].feeRatioPermillage = _feeRatio;

        emit PassFeeSet(pass, _feeRatio);
    }

    function getPassFee(address pass) public view checkPass(pass) returns (uint16) {
        return passProperty[pass].feeRatioPermillage;
    }

    function setPassInfo(address pass, PassInfo memory info)
        public whenNotPaused checkPass(pass) checkPassOwner(pass, _msgSender()) {

        _setPassInfo(pass, info);
    }

    function _setPassInfo(address pass, PassInfo memory info) internal {

        require(info.validityPeriod > 0, "PassCenter: Illegal validityPeriod");

        passProperty[pass].info = info;

        emit PassInfoSet(pass, info);
    }

    function getPassInfo(address pass) public view checkPass(pass) returns (PassInfo memory) {
        return passProperty[pass].info;
    }

    function addPassRecords(address pass, string[] memory records)
        public whenNotPaused checkPass(pass) checkPassOwner(pass, _msgSender()) {

        for (uint i = 0; i < records.length; i++) {
            passProperty[pass].records.push(records[i]);
            emit PassRecordAdded(pass, records[i]);
        }
    }

    function getPassRecords(address pass) public view checkPass(pass) returns (string[] memory) {
        return passProperty[pass].records;
    }

    function getPassIssuanceInfo(address pass)
        public view checkPass(pass) returns (uint256 totalSupply, uint256 claimed) {

        totalSupply = passProperty[pass].totalSupply;
        claimed = passProperty[pass].tokenIdTracker.current();
    }

    /**
     * PassToken
     */

    modifier checkPassToken(address pass, uint256 tokenId) {
        require(
            tokenId != 0 && tokenId <= passProperty[pass].tokenIdTracker.current(),
            "PassCenter: Illegal tokenId"
        );
        _;
    }

    function getPassTokenInfo(address pass, uint256 tokenId)
        public view checkPass(pass) checkPassToken(pass, tokenId) returns (PassTokenInfo memory) {

        return passProperty[pass].tokenInfo[tokenId];
    }

    function addPassTokenRecords(address pass, uint256 tokenId, string[] memory records)
        public whenNotPaused checkPass(pass) checkPassToken(pass, tokenId) checkPassOwner(pass, _msgSender()) {

        for (uint i = 0; i < records.length; i++) {
            passProperty[pass].tokenRecords[tokenId].push(records[i]);
            emit PassTokenRecordAdded(pass, tokenId, records[i]);
        }
    }

    function getPassTokenRecords(address pass, uint256 tokenId)
        public view checkPass(pass) checkPassToken(pass, tokenId) returns (string[] memory) {

        return passProperty[pass].tokenRecords[tokenId];
    }

    function mintPassToken(address pass, uint256 _supply)
        public whenNotPaused checkPass(pass) checkPassOwner(pass, _msgSender()) {

        _mintPassToken(pass, _supply);
    }

    function _mintPassToken(address pass, uint256 _supply) internal {

        require(_supply > 0, "PassCenter: Illegal supply");

        PassProperty storage property = passProperty[pass];
        property.totalSupply += _supply;

        emit PassTokenMinted(pass, _supply);
    }

    function claimPassToken(address pass) public payable whenNotPaused checkPass(pass) {

        PassProperty storage property = passProperty[pass];
        uint256 price = property.info.claimPrice;
        require(price == msg.value, "PassCenter: Send value is not equals price");

        property.tokenIdTracker.increment();
        uint256 tokenId = property.tokenIdTracker.current();

        require(tokenId <= property.totalSupply, "PassCenter: Sold out");

        Pass(pass).mint(_msgSender(), tokenId);

        uint256 expiredAt = block.timestamp + property.info.validityPeriod;
        property.tokenInfo[tokenId] = PassTokenInfo(
            property.info.coverURI,
            property.info.name,
            property.info.domain,
            expiredAt
        );

        // Pay
        address receiver = property.info.feeReceiver;
        uint256 amount = _pay(pass, receiver, price);

        emit PassTokenClaimed(pass, tokenId, property.tokenInfo[tokenId], receiver, amount);
    }

    function renewPassToken(address pass, uint256 tokenId)
        public payable whenNotPaused checkPass(pass) {

        PassProperty storage property = passProperty[pass];
        uint256 price = property.info.renewalPrice;
        require(price == msg.value, "PassCenter: Send value is not equals price");

        require(Pass(pass).ownerOf(tokenId) == _msgSender(), "PassCenter: Illegal tokenOwner");

        uint256 newExpiredAt;
        uint256 oldExpiredAt = property.tokenInfo[tokenId].expiredAt;
        if (oldExpiredAt < block.timestamp) {
            // Expired
            newExpiredAt = block.timestamp + property.info.validityPeriod;

        } else {
            // It can be renewed only when the remaining effective time is less than one renewal cycle
            uint256 remainTime = oldExpiredAt - block.timestamp;
            require(
                remainTime < property.info.validityPeriod,
                "PassCenter: Remaining validity time is not less than validityPeriod"
            );

            newExpiredAt = oldExpiredAt + property.info.validityPeriod;
        }
        property.tokenInfo[tokenId].expiredAt = newExpiredAt;

        // Pay
        address receiver = property.info.feeReceiver;
        uint256 amount = _pay(pass, receiver, price);

        emit PassTokenRenewed(pass, tokenId, newExpiredAt, receiver, amount);
    }

    function _pay(address pass, address receiver, uint256 price) internal returns (uint256) {

        if (price == 0) {
            return 0;
        }

        // Truncation occurs when price * feeRatioPermillage < 1000
        uint256 amountFee = price * passProperty[pass].feeRatioPermillage / 1000;
        uint256 amountRemain = price - amountFee;

        payable(feeReceiver).transfer(amountFee);
        payable(receiver).transfer(amountRemain);

        return amountRemain;
    }

}