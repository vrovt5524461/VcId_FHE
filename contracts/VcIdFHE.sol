// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool, euint64 } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract VcIdFHE is SepoliaConfig {
    struct EncryptedCredential {
        uint256 id;
        address issuer;
        euint32 encryptedCredentialType;
        euint32 encryptedAttributes;
        euint32 encryptedExpiry;
        uint256 timestamp;
    }

    struct CompositeProof {
        euint32 encryptedCompositeScore;
        bool isRevealed;
        uint256 timestamp;
    }

    mapping(address => EncryptedCredential[]) private userCredentials;
    mapping(address => CompositeProof) private userProofs;
    mapping(uint256 => address) private requestToUser;

    event CredentialAdded(address indexed user, address indexed issuer);
    event ProofGenerationRequested(address indexed user);
    event ProofGenerated(address indexed user);
    event ProofRevealed(address indexed user);

    modifier onlyCredentialOwner() {
        require(userCredentials[msg.sender].length > 0, "No credentials");
        _;
    }

    /// @notice Add encrypted verifiable credential
    function addCredential(
        address user,
        euint32 credentialType,
        euint32 attributes,
        euint32 expiry
    ) public {
        uint256 newId = userCredentials[user].length;
        userCredentials[user].push(EncryptedCredential({
            id: newId,
            issuer: msg.sender,
            encryptedCredentialType: credentialType,
            encryptedAttributes: attributes,
            encryptedExpiry: expiry,
            timestamp: block.timestamp
        }));

        emit CredentialAdded(user, msg.sender);
    }

    /// @notice Request composite proof generation
    function requestProofGeneration() public onlyCredentialOwner {
        EncryptedCredential[] storage creds = userCredentials[msg.sender];
        bytes32[] memory ciphertexts = new bytes32[](creds.length * 3);
        
        uint counter = 0;
        for (uint i = 0; i < creds.length; i++) {
            ciphertexts[counter++] = FHE.toBytes32(creds[i].encryptedCredentialType);
            ciphertexts[counter++] = FHE.toBytes32(creds[i].encryptedAttributes);
            ciphertexts[counter++] = FHE.toBytes32(creds[i].encryptedExpiry);
        }

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.generateProof.selector);
        requestToUser[reqId] = msg.sender;

        emit ProofGenerationRequested(msg.sender);
    }

    /// @notice Generate composite proof from credentials
    function generateProof(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        address user = requestToUser[requestId];
        require(user != address(0), "Invalid request");

        FHE.checkSignatures(requestId, cleartexts, proof);

        uint32[] memory values = abi.decode(cleartexts, (uint32[]));
        
        // Calculate composite score (simplified example)
        euint32 compositeScore = FHE.asEuint32(0);
        uint validCreds = 0;
        
        for (uint i = 0; i < values.length / 3; i++) {
            uint32 credType = values[i*3];
            uint32 attributes = values[i*3+1];
            uint32 expiry = values[i*3+2];
            
            // Skip expired credentials
            if (expiry > block.timestamp) {
                // Weighted sum based on credential type and attributes
                euint32 weightedScore = FHE.mul(
                    FHE.asEuint32(credType),
                    FHE.asEuint32(attributes)
                );
                compositeScore = FHE.add(compositeScore, weightedScore);
                validCreds++;
            }
        }

        if (validCreds > 0) {
            userProofs[user] = CompositeProof({
                encryptedCompositeScore: FHE.div(compositeScore, FHE.asEuint32(validCreds)),
                isRevealed: false,
                timestamp: block.timestamp
            });
        }

        emit ProofGenerated(user);
    }

    /// @notice Request proof reveal
    function requestProofReveal() public onlyCredentialOwner {
        require(!userProofs[msg.sender].isRevealed, "Already revealed");
        require(FHE.isInitialized(userProofs[msg.sender].encryptedCompositeScore), "No proof");

        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(userProofs[msg.sender].encryptedCompositeScore);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.finalizeReveal.selector);
        requestToUser[reqId] = msg.sender;
    }

    /// @notice Finalize proof reveal
    function finalizeReveal(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        address user = requestToUser[requestId];
        require(user != address(0), "Invalid request");

        FHE.checkSignatures(requestId, cleartexts, proof);

        userProofs[user].isRevealed = true;
        emit ProofRevealed(user);
    }

    /// @notice Get credential count for a user
    function getCredentialCount(address user) public view returns (uint256) {
        return userCredentials[user].length;
    }

    /// @notice Check if proof exists for a user
    function hasProof(address user) public view returns (bool) {
        return FHE.isInitialized(userProofs[user].encryptedCompositeScore);
    }
}