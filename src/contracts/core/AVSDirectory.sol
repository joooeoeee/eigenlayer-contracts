// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/security/ReentrancyGuardUpgradeable.sol";
import "../permissions/Pausable.sol";
import "../libraries/EIP1271SignatureUtils.sol";
import "../libraries/EpochUtils.sol";
import "../libraries/SlashingAccountingUtils.sol";
import "./AVSDirectoryStorage.sol";

contract AVSDirectory is
    Initializable,
    OwnableUpgradeable,
    Pausable,
    AVSDirectoryStorage,
    ReentrancyGuardUpgradeable
{
    /// @dev Index for flag that pauses operator register/deregister to avs when set.
    uint8 internal constant PAUSED_OPERATOR_REGISTER_DEREGISTER_TO_AVS = 0;

    /// @dev Chain ID at the time of contract deployment
    uint256 internal immutable ORIGINAL_CHAIN_ID;

    /// @notice Canonical, virtual beacon chain ETH strategy
    IStrategy public constant beaconChainETHStrategy = IStrategy(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);

    /**
     *
     *                         INITIALIZING FUNCTIONS
     *
     */

    /**
     * @dev Initializes the immutable addresses of the strategy mananger, delegationManager, slasher,
     * and eigenpodManager contracts
     */
    constructor(
        IDelegationManager _delegation,
        IStrategyManager _strategyManager
    ) AVSDirectoryStorage(_delegation, _strategyManager) {
        _disableInitializers();
        ORIGINAL_CHAIN_ID = block.chainid;
    }

    /**
     * @dev Initializes the addresses of the initial owner, pauser registry, and paused status.
     * minWithdrawalDelayBlocks is set only once here
     */
    function initialize(
        address initialOwner,
        IPauserRegistry _pauserRegistry,
        uint256 initialPausedStatus
    ) external initializer {
        _initializePauser(_pauserRegistry, initialPausedStatus);
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        _transferOwnership(initialOwner);
    }

    /**
     *
     *                         EXTERNAL FUNCTIONS
     *
     */

    /**
     * @notice Updates the standby parameters for an operator across multiple operator sets.
     * Allows the AVS to add the operator to a given operator set if they are not already registered.
     *
     * @param operator The address of the operator for which the standby parameters are being updated.
     * @param standbyParams The new standby parameters for the operator.
     * @param operatorSignature If non-empty, the signature of the operator authorizing the modification.
     *                  If empty, the `msg.sender` must be the operator.
     */
    function updateStandbyParams(
        address operator,
        StandbyParam[] calldata standbyParams,
        SignatureWithSaltAndExpiry calldata operatorSignature
    ) external {
        if (operatorSignature.signature.length == 0) {
            // Assert caller is `operator` if signature length is zero.
            require(msg.sender == operator, "AVSDirectory.updateStandbyParams: invalid signature");
        } else {
            // Assert operator's signature has not expired.
            require(
                operatorSignature.expiry >= block.timestamp,
                "AVSDirectory.updateStandbyParams: operator signature expired"
            );
            // Assert operator's signature cannot be replayed.
            require(
                !operatorSaltIsSpent[operator][operatorSignature.salt], "AVSDirectory.updateStandbyParams: salt spent"
            );
            // Assert operator's signature is valid.
            EIP1271SignatureUtils.checkSignature_EIP1271(
                operator,
                calculateUpdateStandbyDigestHash(standbyParams, operatorSignature.salt, operatorSignature.expiry),
                operatorSignature.signature
            );
            // Spend salt.
            operatorSaltIsSpent[operator][operatorSignature.salt] = true;
        }

        for (uint256 i; i < standbyParams.length; ++i) {
            onStandby[standbyParams[i].operatorSet.avs][operator][standbyParams[i].operatorSet.id] =
                standbyParams[i].onStandby;

            emit StandbyParamUpdated(operator, standbyParams[i].operatorSet, standbyParams[i].onStandby);
        }
    }

    /**
     *  @notice Called by AVSs to add an operator to an operator set.
     *
     *  @param operator The address of the operator to be added to the operator set.
     *  @param operatorSetIds The IDs of the operator sets.
     *  @param operatorSignature The signature of the operator on their intent to register.
     *
     *  @dev msg.sender is used as the AVS.
     *  @dev The operator must not have a pending deregistration from the operator set.
     *  @dev If this is the first operator set in the AVS that the operator is
     *  registering for, a OperatorAVSRegistrationStatusUpdated event is emitted with
     *  a REGISTERED status.
     */
    function registerOperatorToOperatorSets(
        address operator,
        uint32[] calldata operatorSetIds,
        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature
    ) external onlyWhenNotPaused(PAUSED_OPERATOR_REGISTER_DEREGISTER_TO_AVS) {
        // Assert `operator` is actually an operator.
        require(
            delegation.isOperator(operator),
            "AVSDirectory.registerOperatorToOperatorSets: operator not registered to EigenLayer yet"
        );
        // Assert operator's signature has not expired.
        require(
            operatorSignature.expiry >= block.timestamp,
            "AVSDirectory.registerOperatorToOperatorSets: operator signature expired"
        );
        // Assert operator's signature `salt` has not already been spent.
        require(
            !operatorSaltIsSpent[operator][operatorSignature.salt],
            "AVSDirectory.registerOperatorToOperatorSets: salt already spent"
        );

        if (operatorSignature.signature.length != 0) {
            // Assert signature provided by `operator` is valid.
            EIP1271SignatureUtils.checkSignature_EIP1271(
                operator,
                calculateOperatorSetRegistrationDigestHash({
                    avs: msg.sender,
                    operatorSetIds: operatorSetIds,
                    salt: operatorSignature.salt,
                    expiry: operatorSignature.expiry
                }),
                operatorSignature.signature
            );
        }

        // Mutate `operatorSaltIsSpent` to `true` to prevent future respending.
        operatorSaltIsSpent[operator][operatorSignature.salt] = true;

        // Register `operator` if not already registered.
        if (avsOperatorStatus[msg.sender][operator] != OperatorAVSRegistrationStatus.REGISTERED) {
            avsOperatorStatus[msg.sender][operator] = OperatorAVSRegistrationStatus.REGISTERED;
            emit OperatorAVSRegistrationStatusUpdated(operator, msg.sender, OperatorAVSRegistrationStatus.REGISTERED);
        }

        // Loop over `operatorSetIds` array and register `operator` for each item.
        for (uint256 i = 0; i < operatorSetIds.length; ++i) {
            // Assert avs is on standby mode for the given `operator` and `operatorSetIds[i]`.
            if (operatorSignature.signature.length == 0) {
                require(
                    onStandby[msg.sender][operator][operatorSetIds[i]],
                    "AVSDirectory.registerOperatorToOperatorSets: avs not on standby"
                );
            }

            // Assert `operator` has not already been registered to `operatorSetIds[i]`.
            require(
                !isOperatorInOperatorSet[msg.sender][operator][operatorSetIds[i]],
                "AVSDirectory.registerOperatorToOperatorSets: operator already registered to operator set"
            );

            // Mutate calling AVS to operator set AVS status, preventing further legacy registrations.
            if (!isOperatorSetAVS[msg.sender]) isOperatorSetAVS[msg.sender] = true;

            // Mutate `isOperatorInOperatorSet` to `true` for `operatorSetIds[i]`.
            isOperatorInOperatorSet[msg.sender][operator][operatorSetIds[i]] = true;

            emit OperatorAddedToOperatorSet(operator, OperatorSet({avs: msg.sender, id: operatorSetIds[i]}));
        }

        // Increase `operatorAVSOperatorSetCount` by `operatorSetIds.length`.
        // You would have to add the operator to 2**256-2 operator sets before overflow is possible here.
        unchecked {
            operatorAVSOperatorSetCount[msg.sender][operator] += operatorSetIds.length;
        }
    }

    /**
     *  @notice Called by AVSs or operators to remove an operator from an operator set.
     *
     *  @param operator The address of the operator to be removed from the operator set.
     *  @param operatorSetIds The IDs of the operator sets.
     *
     *  @dev msg.sender is used as the AVS.
     *  @dev The operator must be registered for the msg.sender AVS and the given operator set.
     *  @dev If this call removes the operator from all operator sets for the msg.sender AVS,
     *  then an OperatorAVSRegistrationStatusUpdated event is emitted with a DEREGISTERED status.
     */
    function deregisterOperatorFromOperatorSets(
        address operator,
        uint32[] calldata operatorSetIds
    ) external onlyWhenNotPaused(PAUSED_OPERATOR_REGISTER_DEREGISTER_TO_AVS) {
        // Loop over `operatorSetIds` array and deregister `operator` for each item.
        for (uint256 i = 0; i < operatorSetIds.length; ++i) {
            // Assert `operator` is registered for this iterations operator set.
            require(
                isOperatorInOperatorSet[msg.sender][operator][operatorSetIds[i]],
                "AVSDirectory.deregisterOperatorFromOperatorSet: operator not registered for operator set"
            );

            // Mutate `isOperatorInOperatorSet` to `false` for `operatorSetIds[i]`.
            isOperatorInOperatorSet[msg.sender][operator][operatorSetIds[i]] = false;

            // Decrement `operatorAVSOperatorSetCount` by 1.
            // The above assertion makes underflow logically impossible here.
            unchecked {
                --operatorAVSOperatorSetCount[msg.sender][operator];
            }

            emit OperatorRemovedFromOperatorSet(operator, OperatorSet({avs: msg.sender, id: operatorSetIds[i]}));
        }

        // Set the operator as deregistered if no longer registered for any operator sets
        if (operatorAVSOperatorSetCount[msg.sender][operator] == 0) {
            avsOperatorStatus[msg.sender][operator] = OperatorAVSRegistrationStatus.UNREGISTERED;
            emit OperatorAVSRegistrationStatusUpdated(operator, msg.sender, OperatorAVSRegistrationStatus.UNREGISTERED);
        }
    }

    /**
     *  @notice Called by the AVS's service manager contract to register an operator with the AVS.
     *
     *  @param operator The address of the operator to register.
     *  @param operatorSignature The signature, salt, and expiry of the operator's signature.
     *
     *  @dev msg.sender must be the AVS.
     *  @dev Only used by legacy M2 AVSs that have not integrated with operator sets.
     */
    function registerOperatorToAVS(
        address operator,
        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature
    ) external onlyWhenNotPaused(PAUSED_OPERATOR_REGISTER_DEREGISTER_TO_AVS) {
        require(
            operatorSignature.expiry >= block.timestamp,
            "AVSDirectory.registerOperatorToAVS: operator signature expired"
        );
        require(
            avsOperatorStatus[msg.sender][operator] != OperatorAVSRegistrationStatus.REGISTERED,
            "AVSDirectory.registerOperatorToAVS: operator already registered"
        );
        require(
            !operatorSaltIsSpent[operator][operatorSignature.salt],
            "AVSDirectory.registerOperatorToAVS: salt already spent"
        );
        require(
            delegation.isOperator(operator),
            "AVSDirectory.registerOperatorToAVS: operator not registered to EigenLayer yet"
        );
        require(
            !isOperatorSetAVS[msg.sender],
            "AVSDirectory.registerOperatorToAVS: operator set AVS cannot register operators with legacy method"
        );

        // Calculate the digest hash
        bytes32 operatorRegistrationDigestHash = calculateOperatorAVSRegistrationDigestHash({
            operator: operator,
            avs: msg.sender,
            salt: operatorSignature.salt,
            expiry: operatorSignature.expiry
        });

        // Check that the signature is valid
        EIP1271SignatureUtils.checkSignature_EIP1271(
            operator, operatorRegistrationDigestHash, operatorSignature.signature
        );

        // Set the operator as registered
        avsOperatorStatus[msg.sender][operator] = OperatorAVSRegistrationStatus.REGISTERED;

        // Mark the salt as spent
        operatorSaltIsSpent[operator][operatorSignature.salt] = true;

        emit OperatorAVSRegistrationStatusUpdated(operator, msg.sender, OperatorAVSRegistrationStatus.REGISTERED);
    }

    /**
     *  @notice Called by an AVS to deregister an operator from the AVS.
     *
     *  @param operator The address of the operator to deregister.
     *
     *  @dev Only used by legacy M2 AVSs that have not integrated with operator sets.
     */
    function deregisterOperatorFromAVS(address operator)
        external
        onlyWhenNotPaused(PAUSED_OPERATOR_REGISTER_DEREGISTER_TO_AVS)
    {
        require(
            avsOperatorStatus[msg.sender][operator] == OperatorAVSRegistrationStatus.REGISTERED,
            "AVSDirectory.deregisterOperatorFromAVS: operator not registered"
        );

        // Set the operator as deregistered
        avsOperatorStatus[msg.sender][operator] = OperatorAVSRegistrationStatus.UNREGISTERED;

        emit OperatorAVSRegistrationStatusUpdated(operator, msg.sender, OperatorAVSRegistrationStatus.UNREGISTERED);
    }

    /**
     *  @notice Called by an AVS to emit an `AVSMetadataURIUpdated` event indicating the information has updated.
     *
     *  @param metadataURI The URI for metadata associated with an AVS.
     *
     *  @dev Note that the `metadataURI` is *never stored* and is only emitted in the `AVSMetadataURIUpdated` event.
     */
    function updateAVSMetadataURI(string calldata metadataURI) external {
        emit AVSMetadataURIUpdated(msg.sender, metadataURI);
    }

    /**
     * @notice Called by an operator to cancel a salt that has been used to register with an AVS.
     *
     * @param salt A unique and single use value associated with the approver signature.
     */
    function cancelSalt(bytes32 salt) external {
        operatorSaltIsSpent[msg.sender][salt] = true;
    }

    struct TotalMagnitudeUpdate {
        uint32 epoch;
        uint64 nonSlashableMagnitude;
        uint64 totalAllocatedMagnitude;
    }

    struct MagnitudeUpdate {
        uint32 epoch;
        uint64 magnitude;
    }

    mapping(address => mapping(IStrategy => mapping(address => mapping(uint32 => MagnitudeUpdate[])))) private
        _operatorSetMagnitudeUpdates;
    mapping(address => mapping(IStrategy => TotalMagnitudeUpdate[])) private _totalMagnitudeUpdates;

    /**
     * @notice updates the slashing magnitudes for an operator for a set of
     * operator sets
     *
     * @param operator the operator whom the slashing parameters are being
     * changed
     * @param slashingMagnitudeParams the new slashing parameters
     * @param allocatorSignature if non-empty is the signature of the allocator on
     * the modification. if empty, the msg.sender must be the allocator for the
     * operator
     *
     * @dev changes take effect in 3 epochs for when this function is called
     */
    function updateSlashingMagnitudes(
        address operator,
        SlashingMagnitudeParam[] calldata slashingMagnitudeParams,
        SignatureWithExpiry calldata allocatorSignature
    ) external returns (uint32 effectEpoch) {
        require(msg.sender == operator);
        uint32 currentEpoch = EpochUtils.currentEpoch();
        effectEpoch = EpochUtils.getNextSlashingParameterEffectEpoch(currentEpoch);
        // loop through the slashingMagnitudeParams and update the magnitudes
        for (uint256 i = 0; i < slashingMagnitudeParams.length; i++) {
            IStrategy strategy = slashingMagnitudeParams[i].strategy;

            TotalMagnitudeUpdate memory totalMagnitudeUpdate;
            if (_totalMagnitudeUpdates[operator][strategy].length != 0) {
                totalMagnitudeUpdate =
                    _totalMagnitudeUpdates[operator][strategy][_totalMagnitudeUpdates[operator][strategy].length - 1];
            }
            uint64 newTotalMagnitude;

            for (uint256 j = 0; j < slashingMagnitudeParams[i].operatorSetSlashingParams.length; j++) {
                {
                    MagnitudeUpdate[] storage operatorSetMagnitudeUpdates = _operatorSetMagnitudeUpdates[operator][strategy][slashingMagnitudeParams[i]
                        .operatorSetSlashingParams[j].operatorSet.avs][slashingMagnitudeParams[i].operatorSetSlashingParams[j]
                        .operatorSet
                        .id];

                    MagnitudeUpdate memory prevMagnitudeUpdate;
                    if (operatorSetMagnitudeUpdates.length != 0) {
                        prevMagnitudeUpdate = operatorSetMagnitudeUpdates[operatorSetMagnitudeUpdates.length - 1];
                    }

                    uint32 prevMagnitudeEpoch = prevMagnitudeUpdate.epoch;
                    // push to magnitude updates between current and effect epoch
                    if (prevMagnitudeUpdate.epoch < currentEpoch) {
                        prevMagnitudeUpdate.epoch = currentEpoch;
                    }
                    // push the previous magnitude for each epoch between current and effect that has not been set yet
                    while (prevMagnitudeUpdate.epoch < effectEpoch) {
                        prevMagnitudeUpdate.epoch++;
                        operatorSetMagnitudeUpdates.push(prevMagnitudeUpdate);
                    }

                    newTotalMagnitude = totalMagnitudeUpdate.totalAllocatedMagnitude
                        + slashingMagnitudeParams[i].operatorSetSlashingParams[j].slashableMagnitude
                        - prevMagnitudeUpdate.magnitude;

                    // update the operator set magnitude in place if possible
                    if (prevMagnitudeEpoch != effectEpoch) {
                        operatorSetMagnitudeUpdates.push(
                            MagnitudeUpdate({
                                epoch: effectEpoch,
                                magnitude: slashingMagnitudeParams[i].operatorSetSlashingParams[j].slashableMagnitude
                            })
                        );
                    } else {
                        operatorSetMagnitudeUpdates[operatorSetMagnitudeUpdates.length - 1].magnitude =
                            slashingMagnitudeParams[i].operatorSetSlashingParams[j].slashableMagnitude;
                    }
                }

                emit SlashableMagnitudeUpdated(
                    operator,
                    strategy,
                    slashingMagnitudeParams[i].operatorSetSlashingParams[j].operatorSet,
                    slashingMagnitudeParams[i].operatorSetSlashingParams[j].slashableMagnitude,
                    effectEpoch
                );
            }

            uint32 prevTotalMagnitudeEpoch = totalMagnitudeUpdate.epoch;
            // push to magnitude updates between current and effect epoch
            if (totalMagnitudeUpdate.epoch < currentEpoch) {
                totalMagnitudeUpdate.epoch = currentEpoch;
            }

            // push the previous magnitude for each epoch between current and effect that has not been set yet
            while (totalMagnitudeUpdate.epoch < effectEpoch) {
                totalMagnitudeUpdate.epoch++;
                _totalMagnitudeUpdates[operator][strategy].push(totalMagnitudeUpdate);
            }

            // update the total magnitude in place if possible
            if (prevTotalMagnitudeEpoch != effectEpoch) {
                _totalMagnitudeUpdates[operator][strategy].push(
                    TotalMagnitudeUpdate({
                        epoch: effectEpoch,
                        nonSlashableMagnitude: slashingMagnitudeParams[i].nonSlashableMagnitude,
                        totalAllocatedMagnitude: newTotalMagnitude
                    })
                );
            } else {
                _totalMagnitudeUpdates[operator][strategy][_totalMagnitudeUpdates[operator][strategy].length - 1]
                    .nonSlashableMagnitude = slashingMagnitudeParams[i].nonSlashableMagnitude;
                _totalMagnitudeUpdates[operator][strategy][_totalMagnitudeUpdates[operator][strategy].length - 1]
                    .totalAllocatedMagnitude = newTotalMagnitude;
            }

            emit NonSlashableMagnitudeUpdated(
                operator, strategy, slashingMagnitudeParams[i].nonSlashableMagnitude, effectEpoch
            );
        }

        return effectEpoch;
    }

    address slasher = address(0);

    /**
     * @notice sets magnitudes for the given operator in the next epoch to the current
     * epoch's magnitudes decreased by bipsToSlash
     *
     * @param operator the operator to decrease and lock magnitude updates for
     * @param operatorSet the operator set slashing the operator
     * @param strategies the list of strategies to decrease and lock magnitude updates for
     * @param bipsToDecrease the bips to decrease the operator set's magnitude
     *
     * @dev only called by the Slasher whenever a slashing request is made
     */
    function decreaseAndLockMagnitude(
        address operator,
        OperatorSet calldata operatorSet,
        IStrategy[] calldata strategies,
        uint16 bipsToDecrease
    ) external {
        require(msg.sender == slasher);
        uint32 currentEpoch = EpochUtils.currentEpoch();
        for (uint256 i = 0; i < strategies.length; i++) {
            // get the magnitude update for the current epoch and the epoch before the current epoch
            uint256 currentIndex;
            uint64 magnitudeToDecrease;
            uint64 prevMagnitude;

            // find the operator set magnitude update for the current epoch
            for (
                currentIndex =
                    _operatorSetMagnitudeUpdates[operator][strategies[i]][operatorSet.avs][operatorSet.id].length - 1;
                currentIndex >= 0;
                currentIndex--
            ) {
                if (
                    _operatorSetMagnitudeUpdates[operator][strategies[i]][operatorSet.avs][operatorSet.id][currentIndex]
                        .epoch <= currentEpoch
                ) {
                    prevMagnitude = _operatorSetMagnitudeUpdates[operator][strategies[i]][operatorSet.avs][operatorSet
                        .id][currentIndex].magnitude;
                    magnitudeToDecrease = prevMagnitude * bipsToDecrease / SlashingAccountingUtils.BIPS_FACTOR;
                    break;
                }
            }

            // push or update the next epoch's magnitude
            if (
                currentIndex
                    == _operatorSetMagnitudeUpdates[operator][strategies[i]][operatorSet.avs][operatorSet.id].length - 1
            ) {
                _operatorSetMagnitudeUpdates[operator][strategies[i]][operatorSet.avs][operatorSet.id].push(
                    MagnitudeUpdate({epoch: currentEpoch, magnitude: prevMagnitude - magnitudeToDecrease})
                );
            } else {
                // decrease the magnitude for the next epoch
                _operatorSetMagnitudeUpdates[operator][strategies[i]][operatorSet.avs][operatorSet.id][currentIndex + 1]
                    .magnitude -= magnitudeToDecrease;
            }

            uint64 prevTotalAllocatedMagnitude;

            // find the total magnitude for the current epoch
            for (
                currentIndex = _totalMagnitudeUpdates[operator][strategies[i]].length - 1;
                currentIndex >= 0;
                currentIndex--
            ) {
                if (_totalMagnitudeUpdates[operator][strategies[i]][currentIndex].epoch <= currentEpoch) {
                    prevTotalAllocatedMagnitude =
                        _totalMagnitudeUpdates[operator][strategies[i]][currentIndex].totalAllocatedMagnitude;
                    break;
                }
            }

            // push or update the next epoch's total magnitude
            if (currentIndex == _totalMagnitudeUpdates[operator][strategies[i]].length - 1) {
                _totalMagnitudeUpdates[operator][strategies[i]].push(
                    TotalMagnitudeUpdate({
                        epoch: currentEpoch,
                        nonSlashableMagnitude: _totalMagnitudeUpdates[operator][strategies[i]][currentIndex]
                            .nonSlashableMagnitude,
                        totalAllocatedMagnitude: prevTotalAllocatedMagnitude - magnitudeToDecrease
                    })
                );
            } else {
                _totalMagnitudeUpdates[operator][strategies[i]][currentIndex + 1].totalAllocatedMagnitude -=
                    magnitudeToDecrease;
            }
        }
    }

    /**
     * @notice increases magnitudes back when previous slashing requests are cancelled
     *
     * @param operator the operator to increase magnitudes for
     * @param operatorSet the operator set cancelling slashing for the operator
     * @param strategies the list of strategies to increase magnitudes for
     * @param bipsToIncrease the bips to increase the operator set's magnitude
     *
     * @dev only called by the Slasher whenever a slashing request is cancelled
     */
    function increaseMagnitude(
        address operator,
        OperatorSet calldata operatorSet,
        IStrategy[] calldata strategies,
        uint16 bipsToIncrease
    ) external {}

    /**
     *
     *                         VIEW FUNCTIONS
     *
     */

    /**
     *  @notice Calculates the digest hash to be signed by an operator to register with an AVS.
     *
     *  @param standbyParams The newly updated standby mode parameters.
     *  @param salt A unique and single-use value associated with the approver's signature.
     *  @param expiry The time after which the approver's signature becomes invalid.
     */
    function calculateUpdateStandbyDigestHash(
        StandbyParam[] calldata standbyParams,
        bytes32 salt,
        uint256 expiry
    ) public view returns (bytes32) {
        return _calculateDigestHash(keccak256(abi.encode(OPERATOR_STANDBY_UPDATE, standbyParams, salt, expiry)));
    }

    /**
     *  @notice Calculates the digest hash to be signed by an operator to register with an AVS.
     *
     *  @param operator The account registering as an operator.
     *  @param avs The AVS the operator is registering with.
     *  @param salt A unique and single-use value associated with the approver's signature.
     *  @param expiry The time after which the approver's signature becomes invalid.
     */
    function calculateOperatorAVSRegistrationDigestHash(
        address operator,
        address avs,
        bytes32 salt,
        uint256 expiry
    ) public view returns (bytes32) {
        return
            _calculateDigestHash(keccak256(abi.encode(OPERATOR_AVS_REGISTRATION_TYPEHASH, operator, avs, salt, expiry)));
    }

    /**
     * @notice Calculates the digest hash to be signed by an operator to register with an operator set.
     *
     * @param avs The AVS that operator is registering to operator sets for.
     * @param operatorSetIds An array of operator set IDs the operator is registering to.
     * @param salt A unique and single use value associated with the approver signature.
     * @param expiry Time after which the approver's signature becomes invalid.
     */
    function calculateOperatorSetRegistrationDigestHash(
        address avs,
        uint32[] calldata operatorSetIds,
        bytes32 salt,
        uint256 expiry
    ) public view returns (bytes32) {
        return _calculateDigestHash(
            keccak256(abi.encode(OPERATOR_SET_REGISTRATION_TYPEHASH, avs, operatorSetIds, salt, expiry))
        );
    }

    /// @notice Getter function for the current EIP-712 domain separator for this contract.
    /// @dev The domain separator will change in the event of a fork that changes the ChainID.
    function domainSeparator() public view returns (bytes32) {
        return _calculateDomainSeparator();
    }

    /// @notice Internal function for calculating the current domain separator of this contract
    function _calculateDomainSeparator() internal view returns (bytes32) {
        if (block.chainid == ORIGINAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        } else {
            return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("EigenLayer")), block.chainid, address(this)));
        }
    }

    function _calculateDigestHash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _calculateDomainSeparator(), structHash));
    }
}
