// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CertificateRegistry
 * @notice CertiChain: Academic credential verification on Ethereum.
 * @dev Manages authorized certificate issuers and records certificate hashes
 *      on-chain so anyone can verify authentic degree credentials without
 *      storing sensitive personal information.
 */
contract CertificateRegistry {
    // ------------------------------------------------------------------------
    // STORAGE & STRUCTS
    // ------------------------------------------------------------------------

    /**
     * @dev Structure representing a single academic certificate record.
     *
     * WHY STRUCT PACKING?
     * Storage slots on Ethereum are 32 bytes (256 bits).
     * - address: 20 bytes (160 bits)
     * - uint64:   8 bytes ( 64 bits) -> sufficient for timestamps for billions of years
     * - bool:     1 byte  (  8 bits)
     * Total: 20 + 8 + 1 = 29 bytes <= 32 bytes.
     * All three fields pack together into a single 32-byte storage slot, saving
     * significant SSTORE gas when issuing and SLOAD gas when reading.
     */
    struct Certificate {
        address issuer;
        uint64 issuedAt;
        bool revoked;
    }

    /**
     * @notice The deployer / administrator of this registry contract.
     *
     * WHY IMMUTABLE?
     * The owner is fixed at deployment and cannot be changed. Marking it `immutable`
     * bakes the address directly into the contract bytecode at construction time,
     * avoiding an expensive SLOAD (storage read) opcode on every access.
     */
    address public immutable owner;

    /**
     * @notice Tracks whether an address is an authorized certificate issuer (e.g. university).
     */
    mapping(address => bool) public isIssuer;

    /**
     * @dev Maps a cryptographic certificate hash (bytes32) to its on-chain Certificate record.
     *
     * WHY HASH-ONLY STORAGE (bytes32)?
     * Storing personal data (names, grades, transcripts) on a public blockchain violates
     * data privacy and GDPR, and is expensive in gas. A 32-byte cryptographic hash (keccak256)
     * acts as a one-way fingerprint: cheap to store, impossible to reverse into student data,
     * yet tamper-proof because any change in the source document yields a completely different hash.
     */
    mapping(bytes32 => Certificate) private certificates;

    // ------------------------------------------------------------------------
    // CUSTOM ERRORS
    // ------------------------------------------------------------------------

    /**
     * WHY CUSTOM ERRORS INSTEAD OF REQUIRE STRINGS?
     * In Solidity 0.8.4+, custom errors compile to a 4-byte selector (e.g. bytes4(keccak256("NotOwner()"))).
     * Older `require(condition, "Not Owner")` patterns store and return long ASCII strings,
     * which increases deployment bytecode size and costs significantly more gas on revert.
     */
    error NotOwner();
    error NotIssuer();
    error ZeroHash();
    error AlreadyIssued();
    error NotFound();
    error NotCertificateIssuer();
    error AlreadyRevoked();

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------

    /**
     * WHY INDEXED EVENT PARAMETERS?
     * Ethereum event logs allow up to 3 `indexed` parameters, which become searchable "topics".
     * Verifiers and off-chain indexers (like The Graph or Etherscan) can filter events
     * directly by `issuer` or `certHash` without downloading and scanning all transaction logs.
     */
    event IssuerAdded(address indexed issuer);
    event IssuerRemoved(address indexed issuer);
    event CertificateIssued(bytes32 indexed certHash, address indexed issuer, uint64 issuedAt);
    event CertificateRevoked(bytes32 indexed certHash, address indexed issuer);

    // ------------------------------------------------------------------------
    // MODIFIERS
    // ------------------------------------------------------------------------

    /**
     * @dev Restricts access to the contract owner.
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @dev Restricts access to authorized issuers.
     */
    modifier onlyIssuer() {
        if (!isIssuer[msg.sender]) revert NotIssuer();
        _;
    }

    // ------------------------------------------------------------------------
    // CONSTRUCTOR
    // ------------------------------------------------------------------------

    /**
     * @notice Initializes the contract and sets the deployer as immutable owner.
     */
    constructor() {
        owner = msg.sender;
    }

    // ------------------------------------------------------------------------
    // ISSUER MANAGEMENT (OWNER ONLY)
    // ------------------------------------------------------------------------

    /**
     * @notice Authorizes an institution address to issue and revoke certificates.
     * @dev Only callable by the contract owner. Updates the `isIssuer` mapping and emits `IssuerAdded`.
     * @param issuer The address of the institution (e.g. university wallet) to authorize.
     */
    function addIssuer(address issuer) external onlyOwner {
        isIssuer[issuer] = true;
        emit IssuerAdded(issuer);
    }

    /**
     * @notice Revokes an institution's authorization to issue certificates.
     * @dev Only callable by the contract owner. Updates the `isIssuer` mapping and emits `IssuerRemoved`.
     *      NOTE: Removing an issuer prevents them from issuing new certificates, but previously
     *      issued certificates remain valid unless individually revoked.
     * @param issuer The address of the institution whose authorization is being removed.
     */
    function removeIssuer(address issuer) external onlyOwner {
        isIssuer[issuer] = false;
        emit IssuerRemoved(issuer);
    }

    // ------------------------------------------------------------------------
    // CERTIFICATE LIFECYCLE (ISSUE, REVOKE, VERIFY)
    // ------------------------------------------------------------------------

    /**
     * @notice Issues a new certificate on-chain by recording its cryptographic hash.
     * @dev Only callable by an authorized issuer (`onlyIssuer`).
     *      Reverts if `certHash` is zero (empty) or if this certificate hash was already issued.
     * @param certHash The keccak256 hash (fingerprint) of the certificate document or details.
     */
    function issue(bytes32 certHash) external onlyIssuer {
        // Prevent registering an empty or uninitialized hash
        if (certHash == bytes32(0)) revert ZeroHash();

        // Prevent duplicate registration; issuedAt != 0 indicates the hash already exists
        if (certificates[certHash].issuedAt != 0) revert AlreadyIssued();

        // Cast block.timestamp (uint256) to uint64 for struct packing.
        // Casting to 'uint64' is safe because block.timestamp will not exceed uint64 max (~1.84e19) for 584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 currentTime = uint64(block.timestamp);

        certificates[certHash] = Certificate({
            issuer: msg.sender,
            issuedAt: currentTime,
            revoked: false
        });

        emit CertificateIssued(certHash, msg.sender, currentTime);
    }

    /**
     * @notice Revokes a previously issued certificate (e.g. if cancelled, expelled, or issued in error).
     * @dev Only the original issuer of this exact certificate can revoke it.
     *      Reverts if the certificate does not exist, if caller is not the original issuer,
     *      or if the certificate is already revoked.
     * @param certHash The keccak256 hash of the certificate to revoke.
     */
    function revoke(bytes32 certHash) external {
        Certificate storage cert = certificates[certHash];

        // Ensure the certificate was actually issued before allowing revocation
        if (cert.issuedAt == 0) revert NotFound();

        // Access control: only the institution that issued this certificate can revoke it.
        // Institution B cannot revoke degrees issued by Institution A.
        if (cert.issuer != msg.sender) revert NotCertificateIssuer();

        // Prevent redundant revocation calls
        if (cert.revoked) revert AlreadyRevoked();

        cert.revoked = true;

        emit CertificateRevoked(certHash, msg.sender);
    }

    /**
     * @notice Verifies whether a given certificate hash exists, is valid, and who issued it.
     * @dev Free read-only view function accessible to anyone (employers, visa offices, students).
     *      No transaction fee (gas) is incurred when calling via an eth_call RPC.
     * @param certHash The keccak256 hash of the certificate to check.
     * @return exists True if the certificate was recorded on-chain, false otherwise.
     * @return valid True if the certificate exists and has NOT been revoked (`exists && !revoked`).
     * @return issuer The address of the institution that issued the certificate (or address(0) if not found).
     * @return issuedAt The Unix timestamp when the certificate was issued (or 0 if not found).
     */
    function verify(bytes32 certHash)
        external
        view
        returns (
            bool exists,
            bool valid,
            address issuer,
            uint64 issuedAt
        )
    {
        Certificate memory cert = certificates[certHash];

        exists = (cert.issuedAt != 0);
        valid = exists && !cert.revoked;
        issuer = cert.issuer;
        issuedAt = cert.issuedAt;
    }
}


