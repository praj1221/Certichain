// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CertificateRegistry} from "../src/CertificateRegistry.sol";

/**
 * @title CertificateRegistryTest
 * @notice Comprehensive unit tests for CertiChain (CertificateRegistry).
 * @dev Tests access control, happy paths, edge cases, custom error reverts,
 *      and event emissions using Foundry cheatcodes (vm.prank, vm.expectRevert, vm.expectEmit).
 */
contract CertificateRegistryTest is Test {
    // ------------------------------------------------------------------------
    // TEST STATE & FIXTURES
    // ------------------------------------------------------------------------

    CertificateRegistry public registry;

    // Test addresses
    address public owner;
    address public universityA;
    address public universityB;
    address public stranger;

    // Sample cryptographic certificate hashes (keccak256 of dummy document data)
    bytes32 public sampleCertHash1;
    bytes32 public sampleCertHash2;

    /**
     * @dev Runs before each test function to establish a fresh test environment.
     */
    function setUp() public {
        // Deployer is this test contract
        owner = address(this);

        // Generate clean mock addresses using Foundry's makeAddr cheatcode
        universityA = makeAddr("universityA");
        universityB = makeAddr("universityB");
        stranger = makeAddr("stranger");

        // Compute sample certificate hashes (fingerprints)
        sampleCertHash1 = keccak256("Student: Alice | Degree: B.S. Computer Science | Class of 2026");
        sampleCertHash2 = keccak256("Student: Bob   | Degree: B.S. Data Science      | Class of 2026");

        // Deploy the contract as `owner`
        registry = new CertificateRegistry();
    }

    // ------------------------------------------------------------------------
    // 1. DEPLOYMENT & INITIAL STATE TESTS
    // ------------------------------------------------------------------------

    function test_OwnerIsDeployer() public view {
        // Assert that the immutable owner was set to msg.sender (this test contract)
        assertEq(registry.owner(), owner, "Owner should match the deployer address");
    }

    // ------------------------------------------------------------------------
    // 2. ISSUER MANAGEMENT TESTS (addIssuer / removeIssuer)
    // ------------------------------------------------------------------------

    function test_OwnerCanAddIssuer() public {
        // Owner authorizes universityA
        registry.addIssuer(universityA);

        // Verify state update
        assertTrue(registry.isIssuer(universityA), "universityA should now be an authorized issuer");
    }

    function test_RevertWhen_NonOwnerAddsIssuer() public {
        // vm.prank impersonates `stranger` for the very next external transaction
        vm.prank(stranger);

        // vm.expectRevert ensures the next call reverts with custom error NotOwner
        vm.expectRevert(CertificateRegistry.NotOwner.selector);
        registry.addIssuer(universityA);
    }

    function test_OwnerCanRemoveIssuer() public {
        // First add the issuer
        registry.addIssuer(universityA);
        assertTrue(registry.isIssuer(universityA));

        // Then owner removes authorization
        registry.removeIssuer(universityA);
        assertFalse(registry.isIssuer(universityA), "universityA should no longer be an authorized issuer");
    }

    function test_RevertWhen_NonOwnerRemovesIssuer() public {
        registry.addIssuer(universityA);

        vm.prank(stranger);
        vm.expectRevert(CertificateRegistry.NotOwner.selector);
        registry.removeIssuer(universityA);
    }

    function test_Emit_IssuerAdded() public {
        // vm.expectEmit checks event logs: (checkTopic1, checkTopic2, checkTopic3, checkData)
        // IssuerAdded has 1 indexed parameter (topic1) and no unindexed data.
        vm.expectEmit(true, false, false, false);
        emit CertificateRegistry.IssuerAdded(universityA);

        registry.addIssuer(universityA);
    }

    function test_Emit_IssuerRemoved() public {
        registry.addIssuer(universityA);

        vm.expectEmit(true, false, false, false);
        emit CertificateRegistry.IssuerRemoved(universityA);

        registry.removeIssuer(universityA);
    }

    // ------------------------------------------------------------------------
    // 3. CERTIFICATE ISSUANCE TESTS (issue)
    // ------------------------------------------------------------------------

    function test_IssuerCanIssueCertificate() public {
        // Authorize universityA
        registry.addIssuer(universityA);

        // UniversityA issues sampleCertHash1
        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // Verify on-chain state via verify()
        (bool exists, bool valid, address issuer, uint64 issuedAt) = registry.verify(sampleCertHash1);

        assertTrue(exists, "Certificate should exist");
        assertTrue(valid, "Certificate should be valid (not revoked)");
        assertEq(issuer, universityA, "Issuer should be universityA");
        assertEq(issuedAt, uint64(block.timestamp), "issuedAt should match block.timestamp");
    }

    function test_RevertWhen_NonIssuerIssues() public {
        // Stranger attempts to issue without authorization
        vm.prank(stranger);
        vm.expectRevert(CertificateRegistry.NotIssuer.selector);
        registry.issue(sampleCertHash1);
    }

    function test_RevertWhen_IssuingZeroHash() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        vm.expectRevert(CertificateRegistry.ZeroHash.selector);
        registry.issue(bytes32(0));
    }

    function test_RevertWhen_IssuingDuplicateHash() public {
        registry.addIssuer(universityA);

        // First issuance succeeds
        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // Duplicate issuance of the exact same hash reverts
        vm.prank(universityA);
        vm.expectRevert(CertificateRegistry.AlreadyIssued.selector);
        registry.issue(sampleCertHash1);
    }

    function test_Emit_CertificateIssued() public {
        registry.addIssuer(universityA);

        // CertificateIssued has 2 indexed topics (certHash, issuer) and 1 unindexed data (issuedAt)
        vm.expectEmit(true, true, false, true);
        emit CertificateRegistry.CertificateIssued(sampleCertHash1, universityA, uint64(block.timestamp));

        vm.prank(universityA);
        registry.issue(sampleCertHash1);
    }

    // ------------------------------------------------------------------------
    // 4. CERTIFICATE REVOCATION TESTS (revoke)
    // ------------------------------------------------------------------------

    function test_OriginalIssuerCanRevoke() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // Original issuer revokes certificate
        vm.prank(universityA);
        registry.revoke(sampleCertHash1);

        // Verification must now show exists=true, but valid=false
        (bool exists, bool valid, address issuer, uint64 issuedAt) = registry.verify(sampleCertHash1);

        assertTrue(exists, "Certificate should still exist in record");
        assertFalse(valid, "Certificate should no longer be valid");
        assertEq(issuer, universityA, "Issuer should still be recorded as universityA");
        assertGt(issuedAt, 0, "issuedAt timestamp should be preserved");
    }

    function test_RevertWhen_RevokingNonExistentCertificate() public {
        registry.addIssuer(universityA);

        // Attempting to revoke an unknown hash reverts with NotFound
        vm.prank(universityA);
        vm.expectRevert(CertificateRegistry.NotFound.selector);
        registry.revoke(sampleCertHash1);
    }

    function test_RevertWhen_DifferentIssuerRevokes() public {
        registry.addIssuer(universityA);
        registry.addIssuer(universityB);

        // UniversityA issues the certificate
        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // UniversityB attempts to revoke UniversityA's certificate
        vm.prank(universityB);
        vm.expectRevert(CertificateRegistry.NotCertificateIssuer.selector);
        registry.revoke(sampleCertHash1);
    }

    function test_RevertWhen_OwnerRevokesDifferentIssuerCertificate() public {
        registry.addIssuer(universityA);

        // UniversityA issues certificate
        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // Even contract owner cannot unilaterally revoke an institution's certificate
        vm.expectRevert(CertificateRegistry.NotCertificateIssuer.selector);
        registry.revoke(sampleCertHash1);
    }

    function test_RevertWhen_NonIssuerRevokes() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // Stranger attempts to revoke
        vm.prank(stranger);
        vm.expectRevert(CertificateRegistry.NotCertificateIssuer.selector);
        registry.revoke(sampleCertHash1);
    }

    function test_RevertWhen_AlreadyRevoked() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // First revoke succeeds
        vm.prank(universityA);
        registry.revoke(sampleCertHash1);

        // Second revoke reverts with AlreadyRevoked
        vm.prank(universityA);
        vm.expectRevert(CertificateRegistry.AlreadyRevoked.selector);
        registry.revoke(sampleCertHash1);
    }

    function test_Emit_CertificateRevoked() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        // CertificateRevoked has 2 indexed topics (certHash, issuer) and no unindexed data
        vm.expectEmit(true, true, false, false);
        emit CertificateRegistry.CertificateRevoked(sampleCertHash1, universityA);

        vm.prank(universityA);
        registry.revoke(sampleCertHash1);
    }

    // ------------------------------------------------------------------------
    // 5. VERIFICATION TESTS (verify)
    // ------------------------------------------------------------------------

    function test_VerifyUnknownCertificateReturnsFalse() public view {
        // Querying an unregistered hash returns all zero/false values
        (bool exists, bool valid, address issuer, uint64 issuedAt) = registry.verify(sampleCertHash1);

        assertFalse(exists, "Non-existent hash must return exists=false");
        assertFalse(valid, "Non-existent hash must return valid=false");
        assertEq(issuer, address(0), "Issuer should be zero address");
        assertEq(issuedAt, 0, "issuedAt should be 0");
    }

    function test_VerifyValidCertificate() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        (bool exists, bool valid, address issuer, uint64 issuedAt) = registry.verify(sampleCertHash1);

        assertTrue(exists);
        assertTrue(valid);
        assertEq(issuer, universityA);
        assertEq(issuedAt, uint64(block.timestamp));
    }

    function test_VerifyRevokedCertificate() public {
        registry.addIssuer(universityA);

        vm.prank(universityA);
        registry.issue(sampleCertHash1);

        vm.prank(universityA);
        registry.revoke(sampleCertHash1);

        (bool exists, bool valid, address issuer, uint64 issuedAt) = registry.verify(sampleCertHash1);

        assertTrue(exists, "Revoked cert exists");
        assertFalse(valid, "Revoked cert is not valid");
        assertEq(issuer, universityA);
        assertGt(issuedAt, 0);
    }
}
