pragma solidity ^0.5.0;

import "./lib/SafeMath.sol";
import "./lib/Ownable.sol";
import "./lib/MinterRoles.sol";
import "./lib/IERC20.sol";
import "./lib/IERC1400.sol";

contract ERC1400 is IERC20, IERC1400, Ownable, MinterRole{
    using SafeMath for uint256;

    /************************************* Token description ****************************************/
    string internal _name;
    string internal _symbol;
    uint256 internal _granularity;
    uint256 internal _totalSupply;
    /************************************************************************************************/

    /**************************************** Token behaviours **************************************/
    // Indicate whether the token can still be controlled by operators or not anymore.
    bool internal _isControllable;

    // Indicate whether the token can still be issued by the issuer or not anymore.
    bool internal _isIssuable;
    /************************************************************************************************/

    /********************************** ERC20 Token mappings ****************************************/
    // tokenHolder => balance
    mapping(address => uint256) internal _balances;

    // tokenHolder => spender => amount value
    mapping(address => mapping(address => uint256)) internal _allowed;
    /************************************************************************************************/

    /**************************************** Documents *********************************************/
    struct Doc {
        string docURI;
        bytes32 docHash;
    }
    // partition => Doc
    mapping(bytes32 => Doc) internal _documents;
    /************************************************************************************************/

    /*********************************** Partitions  mappings ***************************************/
    // All partitions.
    bytes32[] internal _totalPartitions;

    // partition => index of _totalPartitions
    mapping(bytes32 => uint256) internal _indexOfTotalPartitions;

    // partition => total supply
    mapping(bytes32 => uint256) internal _totalSupplyByPartition;

    // tokenHolder => partitions (partition[])
    mapping(address => bytes32[]) internal _partitionsOf;

    // tokenHolder => partition => index
    mapping(address => mapping(bytes32 => uint256)) internal _indexOfPartitionsOf;

    // tokenHolder => partition => balance
    mapping(address => mapping(bytes32 => uint256)) internal _balanceOfByPartition;

    // default partitions (erc20)
    bytes32[] internal _defaultPartitions;
    /************************************************************************************************/

    /********************************* Global operators mappings ************************************/
    // operator => tokenHolder => auth | No-auth
    mapping(address => mapping(address => bool)) internal _authorizedOperator;

    // Array of controllers.
    address[] internal _controllers;

    // address => isController | notController
    mapping(address => bool) internal _isController;
    /************************************************************************************************/

    /******************************** Partition operators mappings **********************************/
    // partition => tokenHolder => spender => allowed amount
    mapping(bytes32 => mapping(address => mapping(address => uint256))) internal _allowedByPartition;

    // tokenHolder => partition => operator =>  auth | no-auth
    mapping(address => mapping(bytes32 => mapping(address => bool))) internal _authorizedOperatorByPartition; 

    // partition => controller array
    mapping(bytes32 => address[]) internal _controllersByPartition;
    // partition => controller => is | not
    mapping(bytes32 => mapping(address => bool)) internal _isControllerByPartition;
    /************************************************************************************************/

    /***************************************** Modifiers ********************************************/
    /**
     * if token is issuable.
     */
    modifier isIssuableToken() {
        require(_isIssuable, "55"); // 0x55	funds locked (lockup period)
        _;
    }
    /**
     * if sender is a minter.
     */
    modifier onlyMinter() {
        require(isMinter(msg.sender) || isOwner());
        _;
    }
    /************************************************************************************************/

    /**************************** Events *******************************/
    event ApprovalByPartition(
        bytes32 indexed partition,
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    // TODO emit Transfer
    event Transfer(
        bytes32 indexed _partition,
        address indexed _from,
        address indexed _to,
        uint256 _value
    );

    // Controller Events
    event ControllerTransfer(
        address _controller,
        address indexed _from,
        address indexed _to,
        uint256 _value,
        bytes _data,
        bytes _operatorData
    );

    event ControllerRedemption(
        address _controller,
        address indexed _tokenHolder,
        uint256 _value,
        bytes _data,
        bytes _operatorData
    );

    /************************************************************************************************/

    /**
     * constructor
     * @param name: token name
     * @param symbol: token symbol
     * @param granularity: granularity of the token.
     * @param controllers: array of initial controllers.
     * @param defaultPartitions: default partitions,for ERC20
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 granularity,
        address[] memory controllers,
        bytes32[] memory defaultPartitions
    ) public {
        _name = name;
        _symbol = symbol;
        _totalSupply = 0;
        require(granularity >= 1);
        _granularity = granularity;

        _setControllers(controllers);

        _defaultPartitions = defaultPartitions;

        _isControllable = true;
        _isIssuable = true;
    }

    /************************************************************************************************/
    /****************************** EXTERNAL FUNCTIONS (ERC20 INTERFACE) ****************************/
    /************************************************************************************************/

    /**
     * total amount of token
     * @return Total supply of tokens currently in circulation.
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /**
     * Get the balance of the account with address 'tokenHolder'.
     * @param tokenHolder Address for which the balance is returned.
     * @return Amount of token held by 'tokenHolder' in the token contract.
     */
    function balanceOf(address tokenHolder) external view returns (uint256) {
        return _balances[tokenHolder];
    }

    /**
     * Transfer token for a specified address.
     * @param to The address to transfer to.
     * @param value The value to be transferred.
     * @return A boolean that indicates if the operation was successful.
     */
    function transfer(address to, uint256 value) external returns (bool) {
        _transferByDefaultPartitions(msg.sender, msg.sender, to, value, "");
        return true;
    }

    /**
     * Check the value of tokens that an owner allowed to a spender.
     * @param owner address The address which owns the funds.
     * @param spender address The address which will spend the funds.
     * @return A uint256 specifying the value of tokens still available for the spender.
     */
    function allowance(address owner, address spender)
        external
        view
        returns (uint256)
    {
        return _allowed[owner][spender];
    }

    /**
     * Approve the passed address to spend the specified amount of tokens on behalf of 'msg.sender'.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean that indicates if the operation was successful.
     */
    function approve(address spender, uint256 value) external returns (bool) {
        require(spender != address(0), "56"); // 0x56	invalid sender
        _allowed[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /**
     * Transfer tokens from one address to another.
     * @param from The address which you want to transfer tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean that indicates if the operation was successful.
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        require(
            _isOperator(msg.sender, from) ||
                (value <= _allowed[from][msg.sender]),
            "53"
        ); // 0x53	insufficient allowance

        if (_allowed[from][msg.sender] >= value) {
            _allowed[from][msg.sender] = _allowed[from][msg.sender].sub(value);
        } else {
            _allowed[from][msg.sender] = 0;
        }

        _transferByDefaultPartitions(msg.sender, from, to, value, "");
        return true;
    }

    /************************************************************************************************/
    /****************************** EXTERNAL FUNCTIONS (ERC1400 INTERFACE) **************************/
    /************************************************************************************************/

    /************************************* Document Management **************************************/
    /**
     * Access a document associated with the token.
     * @param name Short name (represented as a bytes32) associated to the document.
     * @return Requested document + document hash.
     */
    function getDocument(bytes32 name)
        external
        view
        returns (string memory, bytes32)
    {
        require(bytes(_documents[name].docURI).length != 0); // Action Blocked - Empty document
        return (_documents[name].docURI, _documents[name].docHash);
    }

    /**
     * Associate a document with the token.
     * @param name Short name (represented as a bytes32) associated to the document.
     * @param uri Document content.
     * @param documentHash Hash of the document [optional parameter].
     */
    function setDocument(
        bytes32 name,
        string calldata uri,
        bytes32 documentHash
    ) external {
        require(_isController[msg.sender]);
        _documents[name] = Doc({docURI: uri, docHash: documentHash});
        emit Document(name, uri, documentHash);
    }

    /************************************************************************************************/

    /************************************** Token Information ***************************************/
    /**
     * Get balance of a tokenholder for a specific partition.
     * @param partition Name of the partition.
     * @param tokenHolder Address for which the balance is returned.
     * @return Amount of token of partition 'partition' held by 'tokenHolder' in the token contract.
     */
    function balanceOfByPartition(bytes32 partition, address tokenHolder)
        external
        view
        returns (uint256)
    {
        return _balanceOfByPartition[tokenHolder][partition];
    }

    /**
     * Get partitions index of a tokenholder.
     * @param tokenHolder Address for which the partitions index are returned.
     * @return Array of partitions index of 'tokenHolder'.
     */
    function partitionsOf(address tokenHolder)
        external
        view
        returns (bytes32[] memory)
    {
        return _partitionsOf[tokenHolder];
    }

    /************************************************************************************************/

    /****************************************** Transfers *******************************************/
    /**
     * Transfer the amount of tokens from the address 'msg.sender' to the address 'to'.
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     * @param data Information attached to the transfer, by the token holder.
     */
    function transferWithData(
        address to,
        uint256 value,
        bytes calldata data
    ) external {
        _transferByDefaultPartitions(msg.sender, msg.sender, to, value, data);
    }

    /**
     * Transfer the amount of tokens on behalf of the address 'from' to the address 'to'.
     * @param from Token holder (or 'address(0)' to set from to 'msg.sender').
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     * @param data Information attached to the transfer, and intended for the token holder ('from').
     */
    function transferFromWithData(
        address from,
        address to,
        uint256 value,
        bytes calldata data
    ) external {
        require(_isOperator(msg.sender, from), "58"); // 0x58	invalid operator (transfer agent)

        _transferByDefaultPartitions(msg.sender, from, to, value, data);
    }

    /************************************************************************************************/

    /********************************** Partition Token Transfers ***********************************/
    /**
     * Transfer tokens from a specific partition.
     * @param partition Name of the partition.
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     * @param data Information attached to the transfer, by the token holder.
     * @return Destination partition.
     */
    function transferByPartition(
        bytes32 partition,
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bytes32) {
        return
            _transferByPartition(
                partition,
                msg.sender,
                msg.sender,
                to,
                value,
                data,
                ""
            );
    }

    /**
     * Transfer tokens from a specific partition through an operator.
     * @param partition Name of the partition.
     * @param from Token holder.
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     * @param data Information attached to the transfer. [CAN CONTAIN THE DESTINATION PARTITION]
     * @param operatorData Information attached to the transfer, by the operator.
     * @return Destination partition.
     */
    function operatorTransferByPartition(
        bytes32 partition,
        address from,
        address to,
        uint256 value,
        bytes calldata data,
        bytes calldata operatorData
    ) external returns (bytes32) {
        require(
            _isOperatorForPartition(partition, msg.sender, from) ||
                (value <= _allowedByPartition[partition][from][msg.sender]),
            "53"
        ); // 0x53	insufficient allowance

        if (_allowedByPartition[partition][from][msg.sender] >= value) {
            _allowedByPartition[partition][from][
                msg.sender
            ] = _allowedByPartition[partition][from][msg.sender].sub(value);
        } else {
            _allowedByPartition[partition][from][msg.sender] = 0;
        }

        return
            _transferByPartition(
                partition,
                msg.sender,
                from,
                to,
                value,
                data,
                operatorData
            );
    }

    /************************************************************************************************/

    /************************************* Controller Operation *************************************/
    /**
     * Know if the token can be controlled by operators.
     * If a token returns 'false' for 'isControllable()'' then it MUST always return 'false' in the future.
     * @return bool 'true' if the token can still be controlled by operators, 'false' if it can't anymore.
     */
    function isControllable() external view returns (bool) {
        return _isControllable;
    }

    /************************************************************************************************/

    /************************************* Operator Management **************************************/
    /**
     * Set a third party operator address as an operator of 'msg.sender' to transfer
     * and redeem tokens on its behalf.
     * @param operator Address to set as an operator for 'msg.sender'.
     */
    function authorizeOperator(address operator) external {
        require(operator != msg.sender);
        _authorizedOperator[operator][msg.sender] = true;
        emit AuthorizedOperator(operator, msg.sender);
    }

    /**
     * Remove the right of the operator address to be an operator for 'msg.sender'
     * and to transfer and redeem tokens on its behalf.
     * @param operator Address to rescind as an operator for 'msg.sender'.
     */
    function revokeOperator(address operator) external {
        require(operator != msg.sender);
        _authorizedOperator[operator][msg.sender] = false;
        emit RevokedOperator(operator, msg.sender);
    }

    /**
     * Set 'operator' as an operator for 'msg.sender' for a given partition.
     * @param partition Name of the partition.
     * @param operator Address to set as an operator for 'msg.sender'.
     */
    function authorizeOperatorByPartition(bytes32 partition, address operator)
        external
    {
        _authorizedOperatorByPartition[msg.sender][partition][operator] = true;
        emit AuthorizedOperatorByPartition(partition, operator, msg.sender);
    }

    /**
     * Remove the right of the operator address to be an operator on a given
     * partition for 'msg.sender' and to transfer and redeem tokens on its behalf.
     * @param partition Name of the partition.
     * @param operator Address to rescind as an operator on given partition for 'msg.sender'.
     */
    function revokeOperatorByPartition(bytes32 partition, address operator)
        external
    {
        _authorizedOperatorByPartition[msg.sender][partition][operator] = false;
        emit RevokedOperatorByPartition(partition, operator, msg.sender);
    }

    /************************************************************************************************/

    /************************************* Operator Information *************************************/
    /**
     * Indicate whether the operator address is an operator of the tokenHolder address.
     * @param operator Address which may be an operator of tokenHolder.
     * @param tokenHolder Address of a token holder which may have the operator address as an operator.
     * @return 'true' if operator is an operator of 'tokenHolder' and 'false' otherwise.
     */
    function isOperator(address operator, address tokenHolder)
        external
        view
        returns (bool)
    {
        return _isOperator(operator, tokenHolder);
    }

    /**
     * Indicate whether the operator address is an operator of the tokenHolder
     * address for the given partition.
     * @param partition Name of the partition.
     * @param operator Address which may be an operator of tokenHolder for the given partition.
     * @param tokenHolder Address of a token holder which may have the operator address as an operator for the given partition.
     * @return 'true' if 'operator' is an operator of 'tokenHolder' for partition 'partition' and 'false' otherwise.
     */
    function isOperatorForPartition(
        bytes32 partition,
        address operator,
        address tokenHolder
    ) external view returns (bool) {
        return _isOperatorForPartition(partition, operator, tokenHolder);
    }

    /************************************************************************************************/

    /**************************************** Token Issuance ****************************************/
    /**
     * Know if new tokens can be issued in the future.
     * @return bool 'true' if tokens can still be issued by the issuer, 'false' if they can't anymore.
     */
    function isIssuable() external view returns (bool) {
        return _isIssuable;
    }

    /**
     * Issue tokens from default partition.
     * @param tokenHolder Address for which we want to issue tokens.
     * @param value Number of tokens issued.
     * @param data Information attached to the issuance, by the issuer.
     */
    function issue(
        address tokenHolder,
        uint256 value,
        bytes calldata data
    ) external onlyMinter isIssuableToken {
        require(_defaultPartitions.length != 0, "55"); // 0x55	funds locked (lockup period)

        _issueByPartition(
            _defaultPartitions[0],
            msg.sender,
            tokenHolder,
            value,
            data
        );
    }

    /**
     * Issue tokens from a specific partition.
     * @param partition Name of the partition.
     * @param tokenHolder Address for which we want to issue tokens.
     * @param value Number of tokens issued.
     * @param data Information attached to the issuance, by the issuer.
     */
    function issueByPartition(
        bytes32 partition,
        address tokenHolder,
        uint256 value,
        bytes calldata data
    ) external onlyMinter isIssuableToken {
        _issueByPartition(partition, msg.sender, tokenHolder, value, data);
    }

    /************************************************************************************************/

    /*************************************** Token Redemption ***************************************/
    /**
     * Redeem the amount of tokens from the address 'msg.sender'.
     * @param value Number of tokens to redeem.
     * @param data Information attached to the redemption, by the token holder.
     */
    function redeem(uint256 value, bytes calldata data) external {
        _redeemByDefaultPartitions(msg.sender, msg.sender, value, data);
    }

    /**
     * Redeem the amount of tokens on behalf of the address from.
     * @param from Token holder whose tokens will be redeemed (or address(0) to set from to msg.sender).
     * @param value Number of tokens to redeem.
     * @param data Information attached to the redemption.
     */
    function redeemFrom(
        address from,
        uint256 value,
        bytes calldata data
    ) external {
        require(_isOperator(msg.sender, from), "58"); // 0x58	invalid operator (transfer agent)

        _redeemByDefaultPartitions(msg.sender, from, value, data);
    }

    /**
     * Redeem tokens of a specific partition.
     * @param partition Name of the partition.
     * @param value Number of tokens redeemed.
     * @param data Information attached to the redemption, by the redeemer.
     */
    function redeemByPartition(
        bytes32 partition,
        uint256 value,
        bytes calldata data
    ) external {
        _redeemByPartition(partition, msg.sender, msg.sender, value, data, "");
    }

    /**
     * Redeem tokens of a specific partition.
     * @param partition Name of the partition.
     * @param tokenHolder Address for which we want to redeem tokens.
     * @param value Number of tokens redeemed
     * @param operatorData Information attached to the redemption, by the operator.
     */
    function operatorRedeemByPartition(
        bytes32 partition,
        address tokenHolder,
        uint256 value,
        bytes calldata operatorData
    ) external {
        require(
            _isOperatorForPartition(partition, msg.sender, tokenHolder),
            "58"
        ); // 0x58	invalid operator (transfer agent)

        _redeemByPartition(
            partition,
            msg.sender,
            tokenHolder,
            value,
            "",
            operatorData
        );
    }

    /************************************************************************************************/

    /************************************************************************************************/
    /************************ EXTERNAL FUNCTIONS (ADDITIONAL - NOT MANDATORY) ***********************/
    /************************************************************************************************/

    /************************************ Token description *****************************************/
    /**
     * Get the name of the token, e.g., "MyToken".
     * @return Name of the token.
     */
    function name() external view returns (string memory) {
        return _name;
    }

    /**
     * Get the symbol of the token, e.g., "MYT".
     * @return Symbol of the token.
     */
    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /**
     * Get the number of decimals of the token.
     * @return The number of decimals of the token. For retrocompatibility, decimals are forced to 18 in ERC1400.
     */
    function decimals() external pure returns (uint8) {
        return uint8(18);
    }

    /**
     * Get the smallest part of the token that’s not divisible.
     * @return The smallest non-divisible part of the token.
     */
    function granularity() external view returns (uint256) {
        return _granularity;
    }

    /**
     * Get list of existing partitions.
     * @return Array of all exisiting partitions.
     */
    function totalPartitions() external view returns (bytes32[] memory) {
        return _totalPartitions;
    }

    /**
     * Get the total number of issued tokens for a given partition.
     * @param partition Name of the partition.
     * @return Total supply of tokens currently in circulation, for a given partition.
     */
    function totalSupplyByPartition(bytes32 partition)
        external
        view
        returns (uint256)
    {
        return _totalSupplyByPartition[partition];
    }

    /************************************************************************************************/

    /**************************************** Token behaviours **************************************/
    /**
     * Definitely renounce the possibility to control tokens on behalf of tokenHolders.
     * Once set to false, '_isControllable' can never be set to 'true' again.
     */
    function renounceControl() external onlyOwner {
        _isControllable = false;
    }

    /**
     * Definitely renounce the possibility to issue new tokens.
     * Once set to false, '_isIssuable' can never be set to 'true' again.
     */
    function renounceIssuance() external onlyOwner {
        _isIssuable = false;
    }

    /************************************************************************************************/

    /************************************ Token controllers *****************************************/
    /**
     * Get the list of controllers as defined by the token contract.
     * @return List of addresses of all the controllers.
     */
    function controllers() external view returns (address[] memory) {
        return _controllers;
    }

    /**
     * Get controllers for a given partition.
     * @param partition Name of the partition.
     * @return Array of controllers for partition.
     */
    function controllersByPartition(bytes32 partition)
        external
        view
        returns (address[] memory)
    {
        return _controllersByPartition[partition];
    }

    /**
     * Set list of token controllers.
     * @param operators Controller addresses.
     */
    function setControllers(address[] calldata operators) external onlyOwner {
        _setControllers(operators);
    }

    /**
     * Set list of token partition controllers.
     * @param partition Name of the partition.
     * @param operators Controller addresses.
     */
    function setPartitionControllers(
        bytes32 partition,
        address[] calldata operators
    ) external onlyOwner {
        _setPartitionControllers(partition, operators);
    }

    /************************************************************************************************/

    /********************************* Token default partitions *************************************/
    /**
     * Get default partitions to transfer from.
     * Function used for ERC20 retrocompatibility.
     * For example, a security token may return the bytes32("unrestricted").
     * @return Array of default partitions.
     */
    function getDefaultPartitions() external view returns (bytes32[] memory) {
        return _defaultPartitions;
    }

    /**
     * Set default partitions to transfer from.
     * Function used for ERC20 retrocompatibility.
     * @param partitions partitions to use by default when not specified.
     */
    function setDefaultPartitions(bytes32[] calldata partitions)
        external
        onlyOwner
    {
        _defaultPartitions = partitions;
    }

    /************************************************************************************************/

    /******************************** Partition Token Allowances ************************************/
    /**
     * Check the value of tokens that an owner allowed to a spender.
     * @param partition Name of the partition.
     * @param owner address The address which owns the funds.
     * @param spender address The address which will spend the funds.
     * @return A uint256 specifying the value of tokens still available for the spender.
     */
    function allowanceByPartition(
        bytes32 partition,
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowedByPartition[partition][owner][spender];
    }

    /**
     * Approve the passed address to spend the specified amount of tokens on behalf of 'msg.sender'.
     * @param partition Name of the partition.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean that indicates if the operation was successful.
     */
    function approveByPartition(
        bytes32 partition,
        address spender,
        uint256 value
    ) external returns (bool) {
        require(spender != address(0), "56"); // 0x56	invalid sender
        _allowedByPartition[partition][msg.sender][spender] = value;
        emit ApprovalByPartition(partition, msg.sender, spender, value);
        return true;
    }

    /************************************************************************************************/

    /**************************************** Token Transfers ***************************************/
    /**
     * Perform the transfer of tokens.
     * @param from Token holder.
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     */
    function _transferWithData(
        address from,
        address to,
        uint256 value
    // ) internal isNotMigratedToken {
    ) internal {
        require(_isMultiple(value), "50"); // 0x50	transfer failure
        require(to != address(0), "57"); // 0x57	invalid receiver
        require(_balances[from] >= value, "52"); // 0x52	insufficient balance

        _balances[from] = _balances[from].sub(value);
        _balances[to] = _balances[to].add(value);

        emit Transfer(from, to, value); // ERC20 retrocompatibility
    }

    /**
     * Transfer tokens from a specific partition.
     * @param fromPartition Partition of the tokens to transfer.
     * @param operator The address performing the transfer.
     * @param from Token holder.
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     * @param data Information attached to the transfer. [CAN CONTAIN THE DESTINATION PARTITION]
     * @param operatorData Information attached to the transfer, by the operator (if any).
     * @return Destination partition.
     */
    function _transferByPartition(
        bytes32 fromPartition,
        address operator,
        address from,
        address to,
        uint256 value,
        bytes memory data,
        bytes memory operatorData
    ) internal returns (bytes32) {
        require(_balanceOfByPartition[from][fromPartition] >= value, "52"); // 0x52	insufficient balance

        bytes32 toPartition = fromPartition;

        if (operatorData.length != 0 && data.length >= 64) {
            toPartition = _getDestinationPartition(fromPartition, data);
        }

        _removeTokenFromPartition(from, fromPartition, value);
        _transferWithData(from, to, value);
        _addTokenToPartition(to, toPartition, value);

        emit TransferByPartition(
            fromPartition,
            operator,
            from,
            to,
            value,
            data,
            operatorData
        );

        if (toPartition != fromPartition) {
            emit ChangedPartition(fromPartition, toPartition, value);
        }

        return toPartition;
    }

    /**
     * Transfer tokens from default partitions.
     * Function used for ERC20 retrocompatibility.
     * @param operator The address performing the transfer.
     * @param from Token holder.
     * @param to Token recipient.
     * @param value Number of tokens to transfer.
     * @param data Information attached to the transfer, and intended for the token holder ('from') [CAN CONTAIN THE DESTINATION PARTITION].
     */
    function _transferByDefaultPartitions(
        address operator,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        require(_defaultPartitions.length != 0, "55"); // // 0x55	funds locked (lockup period)

        uint256 _remainingValue = value;
        uint256 _localBalance;

        for (uint256 i = 0; i < _defaultPartitions.length; i++) {
            _localBalance = _balanceOfByPartition[from][_defaultPartitions[i]];
            if (_remainingValue <= _localBalance) {
                _transferByPartition(
                    _defaultPartitions[i],
                    operator,
                    from,
                    to,
                    _remainingValue,
                    data,
                    ""
                );
                _remainingValue = 0;
                break;
            } else if (_localBalance != 0) {
                _transferByPartition(
                    _defaultPartitions[i],
                    operator,
                    from,
                    to,
                    _localBalance,
                    data,
                    ""
                );
                _remainingValue = _remainingValue - _localBalance;
            }
        }

        require(_remainingValue == 0, "52"); // 0x52	insufficient balance
    }

    /**
     * Retrieve the destination partition from the 'data' field.
     * By convention, a partition change is requested ONLY when 'data' starts
     * with the flag: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
     * When the flag is detected, the destination tranche is extracted from the
     * 32 bytes following the flag.
     * @param fromPartition Partition of the tokens to transfer.
     * @param data Information attached to the transfer. [CAN CONTAIN THE DESTINATION PARTITION]
     * @return Destination partition.
     */
    function _getDestinationPartition(bytes32 fromPartition, bytes memory data)
        internal
        pure
        returns (bytes32 toPartition)
    {
        bytes32 changePartitionFlag =
            0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        bytes32 flag;
        assembly {
            flag := mload(add(data, 32))
        }
        if (flag == changePartitionFlag) {
            assembly {
                toPartition := mload(add(data, 64))
            }
        } else {
            toPartition = fromPartition;
        }
    }

    /**
     * Remove a token from a specific partition.
     * @param from Token holder.
     * @param partition Name of the partition.
     * @param value Number of tokens to transfer.
     */
    function _removeTokenFromPartition(
        address from,
        bytes32 partition,
        uint256 value
    ) internal {
        _balanceOfByPartition[from][partition] = _balanceOfByPartition[from][partition].sub(value);
        _totalSupplyByPartition[partition] = _totalSupplyByPartition[partition].sub(value);

        // If the total supply is zero, finds and deletes the partition.
        if (_totalSupplyByPartition[partition] == 0) {
            uint256 index1 = _indexOfTotalPartitions[partition];
            require(index1 > 0, "50"); // 0x50	transfer failure

            // move the last item into the index being vacated
            bytes32 lastValue = _totalPartitions[_totalPartitions.length - 1];
            _totalPartitions[index1 - 1] = lastValue; // adjust for 1-based indexing
            _indexOfTotalPartitions[lastValue] = index1;

            _totalPartitions.length -= 1;
            _indexOfTotalPartitions[partition] = 0;
        }

        // If the balance of the TokenHolder's partition is zero, finds and deletes the partition.
        if (_balanceOfByPartition[from][partition] == 0) {
            uint256 index2 = _indexOfPartitionsOf[from][partition];
            require(index2 > 0, "50"); // 0x50	transfer failure

            // move the last item into the index being vacated
            bytes32 lastValue =
                _partitionsOf[from][_partitionsOf[from].length - 1];
            _partitionsOf[from][index2 - 1] = lastValue; // adjust for 1-based indexing
            _indexOfPartitionsOf[from][lastValue] = index2;

            _partitionsOf[from].length -= 1;
            _indexOfPartitionsOf[from][partition] = 0;
        }
    }

    /**
     * Add a token to a specific partition.
     * @param to Token recipient.
     * @param partition Name of the partition.
     * @param value Number of tokens to transfer.
     */
    function _addTokenToPartition(
        address to,
        bytes32 partition,
        uint256 value
    ) internal {
        if (value != 0) {
            if (_indexOfPartitionsOf[to][partition] == 0) {
                _partitionsOf[to].push(partition);
                _indexOfPartitionsOf[to][partition] = _partitionsOf[to].length;
            }
            _balanceOfByPartition[to][partition] = _balanceOfByPartition[to][partition].add(value);

            if (_indexOfTotalPartitions[partition] == 0) {
                _totalPartitions.push(partition);
                _indexOfTotalPartitions[partition] = _totalPartitions.length;
            }
            _totalSupplyByPartition[partition] = _totalSupplyByPartition[partition].add(value);
        }
    }

    /**
     * Check if 'value' is multiple of the granularity.
     * @param value The quantity that want's to be checked.
     * @return 'true' if 'value' is a multiple of the granularity.
     */
    function _isMultiple(uint256 value) internal view returns (bool) {
        return (value.div(_granularity).mul(_granularity) == value);
    }

    function controllerTransfer(address _from, address _to, uint256 _value, bytes calldata _data, bytes calldata _operatorData) external{
        require(_isController[msg.sender]);
        _transferByDefaultPartitions(msg.sender, _from, _to, _value, _data);
        emit ControllerTransfer(msg.sender, _from, _to, _value, _data, _operatorData);

    }
    function controllerRedeem(address _tokenHolder, uint256 _value, bytes calldata _data, bytes calldata _operatorData) external{
        require(_isController[msg.sender]);
        _redeemByDefaultPartitions(msg.sender, _tokenHolder, _value, _data);
        emit ControllerRedemption(msg.sender, _tokenHolder, _value, _data, _operatorData);

    }


    /************************************* Operator Information *************************************/
    /**
     * Indicate whether the operator address is an operator of the tokenHolder address.
     * @param operator Address which may be an operator of 'tokenHolder'.
     * @param tokenHolder Address of a token holder which may have the 'operator' address as an operator.
     * @return 'true' if 'operator' is an operator of 'tokenHolder' and 'false' otherwise.
     */
    function _isOperator(address operator, address tokenHolder)
        internal
        view
        returns (bool)
    {
        return (operator == tokenHolder ||
            _authorizedOperator[operator][tokenHolder] ||
            (_isControllable && _isController[operator]));
    }

    /**
     * Indicate whether the operator address is an operator of the tokenHolder
     * address for the given partition.
     * @param partition Name of the partition.
     * @param operator Address which may be an operator of tokenHolder for the given partition.
     * @param tokenHolder Address of a token holder which may have the operator address as an operator for the given partition.
     * @return 'true' if 'operator' is an operator of 'tokenHolder' for partition 'partition' and 'false' otherwise.
     */
    function _isOperatorForPartition(
        bytes32 partition,
        address operator,
        address tokenHolder
    ) internal view returns (bool) {
        return (_isOperator(operator, tokenHolder) ||
            _authorizedOperatorByPartition[tokenHolder][partition][operator] ||
            (_isControllable && _isControllerByPartition[partition][operator]));
    }

    /************************************************************************************************/

    /**************************************** Token Issuance ****************************************/
    /**
     * Perform the issuance of tokens.
     * @param operator Address which triggered the issuance.
     * @param to Token recipient.
     * @param value Number of tokens issued.
     * @param data Information attached to the issuance, and intended for the recipient (to).
     */
    function _issue(
        address operator,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        require(_isMultiple(value), "50"); // 0x50	transfer failure
        require(to != address(0), "57"); // 0x57	invalid receiver

        _totalSupply = _totalSupply.add(value);
        _balances[to] = _balances[to].add(value);

        emit Issued(operator, to, value, data);
        emit Transfer(address(0), to, value); // ERC20 retrocompatibility
    }

    /**
     * Issue tokens from a specific partition.
     * @param toPartition Name of the partition.
     * @param operator The address performing the issuance.
     * @param to Token recipient.
     * @param value Number of tokens to issue.
     * @param data Information attached to the issuance.
     */
    function _issueByPartition(
        bytes32 toPartition,
        address operator,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        _issue(operator, to, value, data);
        _addTokenToPartition(to, toPartition, value);

        emit IssuedByPartition(toPartition, operator, to, value, data, "");
    }

    /************************************************************************************************/

    /*************************************** Token Redemption ***************************************/
    /**
     * Perform the token redemption.
     * @param operator The address performing the redemption.
     * @param from Token holder whose tokens will be redeemed.
     * @param value Number of tokens to redeem.
     * @param data Information attached to the redemption.
     */
    function _redeem(
        address operator,
        address from,
        uint256 value,
        bytes memory data
    // ) internal isNotMigratedToken {
    ) internal {
        require(_isMultiple(value), "50"); // 0x50	transfer failure
        require(from != address(0), "56"); // 0x56	invalid sender
        require(_balances[from] >= value, "52"); // 0x52	insufficient balance

        _balances[from] = _balances[from].sub(value);
        _totalSupply = _totalSupply.sub(value);

        emit Redeemed(operator, from, value, data);
        emit Transfer(from, address(0), value); // ERC20 retrocompatibility
    }

    /**
     * Redeem tokens of a specific partition.
     * @param fromPartition Name of the partition.
     * @param operator The address performing the redemption.
     * @param from Token holder whose tokens will be redeemed.
     * @param value Number of tokens to redeem.
     * @param data Information attached to the redemption.
     * @param operatorData Information attached to the redemption, by the operator (if any).
     */
    function _redeemByPartition(
        bytes32 fromPartition,
        address operator,
        address from,
        uint256 value,
        bytes memory data,
        bytes memory operatorData
    ) internal {
        require(_balanceOfByPartition[from][fromPartition] >= value, "52"); // 0x52	insufficient balance

        _removeTokenFromPartition(from, fromPartition, value);
        _redeem(operator, from, value, data);

        emit RedeemedByPartition(
            fromPartition,
            operator,
            from,
            value,
            operatorData
        );
    }

    /**
     * Redeem tokens from a default partitions.
     * @param operator The address performing the redeem.
     * @param from Token holder.
     * @param value Number of tokens to redeem.
     * @param data Information attached to the redemption.
     */
    function _redeemByDefaultPartitions(
        address operator,
        address from,
        uint256 value,
        bytes memory data
    ) internal {
        require(_defaultPartitions.length != 0, "55"); // 0x55	funds locked (lockup period)

        uint256 _remainingValue = value;
        uint256 _localBalance;

        for (uint256 i = 0; i < _defaultPartitions.length; i++) {
            _localBalance = _balanceOfByPartition[from][_defaultPartitions[i]];
            if (_remainingValue <= _localBalance) {
                _redeemByPartition(
                    _defaultPartitions[i],
                    operator,
                    from,
                    _remainingValue,
                    data,
                    ""
                );
                _remainingValue = 0;
                break;
            } else {
                _redeemByPartition(
                    _defaultPartitions[i],
                    operator,
                    from,
                    _localBalance,
                    data,
                    ""
                );
                _remainingValue = _remainingValue - _localBalance;
            }
        }

        require(_remainingValue == 0, "52"); // 0x52	insufficient balance
    }

    /************************************************************************************************/

    /************************************ Token controllers *****************************************/
    /**
     * Set list of token controllers.
     * @param operators Controller addresses.
     */
    function _setControllers(address[] memory operators) internal {
        for (uint256 i = 0; i < _controllers.length; i++) {
            _isController[_controllers[i]] = false;
        }
        for (uint256 j = 0; j < operators.length; j++) {
            _isController[operators[j]] = true;
        }
        _controllers = operators;
    }

    /**
     * Set list of token partition controllers.
     * @param partition Name of the partition.
     * @param operators Controller addresses.
     */
    function _setPartitionControllers(
        bytes32 partition,
        address[] memory operators
    ) internal {
        for ( uint256 i = 0; i < _controllersByPartition[partition].length; i++) {
            _isControllerByPartition[partition][_controllersByPartition[partition][i]] = false;
        }
        for (uint256 j = 0; j < operators.length; j++) {
            _isControllerByPartition[partition][operators[j]] = true;
        }
        _controllersByPartition[partition] = operators;
    }

    /************************************************************************************************/