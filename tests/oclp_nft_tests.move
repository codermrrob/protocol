/// Unit tests for the OCLP Package module.
/// 
/// These tests verify the core functionality of package minting,
/// including rate limiting based on OCLPMintCap and OCLPDomainRegistration.
#[test_only]
module oclp::oclp_package_tests {
    use sui::clock;
    use std::string;
    use oclp::oclp_package;
    use oclp::oclp_domain;

    // ═══════════════════════════════════════════════════════════════════════
    // Test Constants
    // ═══════════════════════════════════════════════════════════════════════

    // Valid 32-byte test hashes
    const TEST_MERKLE_ROOT: vector<u8> = vector[
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20
    ];

    const TEST_MANIFEST_HASH: vector<u8> = vector[
        0x20, 0x1f, 0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x10, 0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01
    ];

    // ═══════════════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════════════

    fun create_test_clock(ctx: &mut tx_context::TxContext): clock::Clock {
        clock::create_for_testing(ctx)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Mint Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies successful package minting with valid domain and mint cap.
    /// 
    /// Value: Confirms the happy path - users with valid credentials can mint
    /// packages. This is the core functionality of the protocol.
    #[test]
    fun test_mint_success() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        // Create test domain registration
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        // Create test mint cap with generous limits (cooldown already passed)
        // Use sender from ctx so mint_cap.minter == ctx.sender()
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,  // 60 second cooldown
            100,    // 100 total mints allowed
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000); // Well past cooldown
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61, // Blake2b-256
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        // Verify package fields
        assert!(oclp_package::get_package_name(&package) == string::utf8(b"Test Package"), 0);
        assert!(oclp_package::get_merkle_integrity_algo(&package) == 61, 1);
        assert!(oclp_package::get_merkle_root(&package) == TEST_MERKLE_ROOT, 2);
        assert!(oclp_package::get_created_at(&package) == 100000, 3);
        assert!(oclp_package::get_package_storage_ref(&package) == b"package_blob_id", 4);
        assert!(oclp_package::get_manifest_version(&package) == string::utf8(b"1.4"), 5);
        assert!(oclp_package::get_manifest_integrity_algo(&package) == 61, 6);
        assert!(oclp_package::get_manifest_hash(&package) == TEST_MANIFEST_HASH, 7);
        assert!(oclp_package::get_manifest_storage_ref(&package) == b"manifest_blob_id", 8);
        assert!(oclp_package::get_oclp_package_version(&package) == 1, 9);
        
        // Verify mint cap was updated
        assert!(oclp_package::get_mint_count(&mint_cap) == 1, 10);
        assert!(oclp_package::get_last_mint_timestamp(&mint_cap) == 100000, 11);
        
        // Cleanup
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that multiple mints work correctly and update counters.
    /// 
    /// Value: Confirms that the mint count increments correctly and that
    /// multiple mints can be performed within limits.
    #[test]
    fun test_multiple_mints_success() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            1000,   // 1 second cooldown
            100,    // 100 total mints allowed
            &mut ctx,
        );




        let mut clock = create_test_clock(&mut ctx);
        
        // First mint at time 10000
        clock::set_for_testing(&mut clock, 10000);
        let package1 = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Package 1"),
            61,
            TEST_MERKLE_ROOT,
            b"blob1",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest1",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        assert!(oclp_package::get_mint_count(&mint_cap) == 1, 0);
        
        // Second mint at time 20000 (past cooldown)
        clock::set_for_testing(&mut clock, 20000);
        let package2 = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Package 2"),
            61,
            TEST_MERKLE_ROOT,
            b"blob2",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest2",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        assert!(oclp_package::get_mint_count(&mint_cap) == 2, 1);
        
        // Third mint at time 30000
        clock::set_for_testing(&mut clock, 30000);
        let package3 = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Package 3"),
            61,
            TEST_MERKLE_ROOT,
            b"blob3",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest3",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        assert!(oclp_package::get_mint_count(&mint_cap) == 3, 2);
        
        // Cleanup
        oclp_package::delete(package1);
        oclp_package::delete(package2);
        oclp_package::delete(package3);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Validation Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that minting fails with an empty package name.
    /// 
    /// Value: Data integrity check. Empty names would create unusable packages
    /// and break UI/indexer assumptions.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_PACKAGE_EMPTY_PACKAGE_NAME)]
    fun test_mint_fails_empty_name() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b""), // Empty name - should fail
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting fails with a short merkle root.
    /// 
    /// Value: Cryptographic integrity check. Merkle roots must be exactly 32 bytes
    /// for proper verification.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_PACKAGE_INVALID_MERKLE_ROOT_LENGTH)]
    fun test_mint_fails_short_merkle_root() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            vector[0x01, 0x02, 0x03], // Only 3 bytes - should fail
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting fails with a long merkle root.
    /// 
    /// Value: Cryptographic integrity check. Merkle roots must be exactly 32 bytes.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_PACKAGE_INVALID_MERKLE_ROOT_LENGTH)]
    fun test_mint_fails_long_merkle_root() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        // 33 bytes - too long
        let long_hash = vector[
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
            0x21
        ];
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            long_hash,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting fails with an invalid manifest hash.
    /// 
    /// Value: Cryptographic integrity check. Manifest hashes must be exactly 32 bytes.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_PACKAGE_INVALID_MANIFEST_HASH_LENGTH)]
    fun test_mint_fails_invalid_manifest_hash() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            vector[0x01, 0x02], // Only 2 bytes - should fail
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MintCap Rate Limit Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that minting fails when cooldown period has not elapsed.
    /// 
    /// Value: Rate limiting protection. Prevents spam minting by enforcing
    /// a minimum time between mints.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS)]
    fun test_mint_fails_cooldown_not_elapsed() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        // Create mint cap with last mint at time 50000 and 60 second cooldown
        let mut mint_cap = oclp_package::create_test_mint_cap_with_count(
            sender,
            60000,  // 60 second cooldown
            50000,  // Last mint at 50000ms
            100,    // Total cap
            1,      // Already minted 1
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        // Set time to 100000ms - cooldown ends at 110000ms (50000 + 60000)
        // So we're still within cooldown
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting succeeds when cooldown period has elapsed.
    /// 
    /// Value: Confirms that rate limiting correctly allows minting after
    /// the cooldown period has passed.
    #[test]
    fun test_mint_succeeds_after_cooldown() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        // Create mint cap with last mint at time 50000 and 60 second cooldown
        let mut mint_cap = oclp_package::create_test_mint_cap_with_count(
            sender,
            60000,  // 60 second cooldown
            50000,  // Last mint at 50000ms
            100,    // Total cap
            1,      // Already minted 1
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        // Set time to 120000ms - well past cooldown (50000 + 60000 = 110000)
        clock::set_for_testing(&mut clock, 120000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        assert!(oclp_package::get_mint_count(&mint_cap) == 2, 0);
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting fails when total mint cap is reached.
    /// 
    /// Value: Prevents unlimited minting. Each mint cap has a maximum number
    /// of mints allowed, protecting against abuse.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS)]
    fun test_mint_fails_total_cap_reached() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        // Create mint cap that has already reached its limit
        let mut mint_cap = oclp_package::create_test_mint_cap_with_count(
            sender,
            1000,   // 1 second cooldown
            0,      // Last mint at time 0
            5,      // Total cap of 5
            5,      // Already minted 5 (at limit)
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000); // Well past cooldown
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
            );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting succeeds when just under the total cap.
    /// 
    /// Value: Confirms boundary condition - minting should work when
    /// mint_count < total_mint_cap.
    #[test]
    fun test_mint_succeeds_at_cap_minus_one() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        // Create mint cap with 4 of 5 mints used
        let mut mint_cap = oclp_package::create_test_mint_cap_with_count(
            sender,
            1000,   // 1 second cooldown
            0,      // Last mint at time 0
            5,      // Total cap of 5
            4,      // Already minted 4 (one more allowed)
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx
        );
        
        assert!(oclp_package::get_mint_count(&mint_cap) == 5, 0);
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that minting fails with wrong minter address.
    /// 
    /// Value: Security check. Mint caps are tied to specific addresses
    /// and cannot be used by other wallets.
    #[test]
    #[expected_failure(abort_code = oclp_package::E_WALLET_INVALID_MINTCAP)]
    fun test_mint_fails_wrong_minter() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        // Create mint cap for a different address than the dummy context sender (@0x0)
        let mut mint_cap = oclp_package::create_test_mint_cap(
            @0xDEAD, // Different from ctx sender
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        // This should fail because ctx sender doesn't match mint_cap.minter
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx
        );
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Delete Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that packages can be deleted.
    /// 
    /// Value: Confirms that package owners can burn their NFTs,
    /// freeing up storage and removing unwanted packages.
    #[test]
    fun test_delete() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Package to Delete"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        // Delete the package
        oclp_package::delete(package);
        
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Accessor Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that get_manifest returns the full manifest struct.
    /// 
    /// Value: Confirms that manifest data is accessible for verification
    /// and display purposes.
    #[test]
    fun test_get_manifest() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.5"),
            62, // Different algo for manifest
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        // Test get_manifest returns full struct
        let manifest = oclp_package::get_manifest(&package);
        let _ = manifest;
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    /// Verifies that get_id returns the correct object ID.
    /// 
    /// Value: Confirms that package IDs can be retrieved for cross-referencing
    /// and indexing purposes.
    #[test]
    fun test_get_id() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        let domain_name = string::utf8(b"test-domain");
        
        let domain_reg = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let mut mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        let mut clock = create_test_clock(&mut ctx);
        clock::set_for_testing(&mut clock, 100000);
        
        let package = oclp_package::mint(
            &domain_reg,
            string::utf8(b"Test Package"),
            61,
            TEST_MERKLE_ROOT,
            b"package_blob_id",
            string::utf8(b"1.4"),
            61,
            TEST_MANIFEST_HASH,
            b"manifest_blob_id",
            &clock,
            &mut mint_cap,
            &mut ctx,
        );
        
        // Verify get_id matches object::id
        let id_from_accessor = oclp_package::get_id(&package);
        let id_from_object = object::id(&package);
        assert!(id_from_accessor == id_from_object, 0);
        
        oclp_package::delete(package);
        oclp_package::delete_test_mint_cap(mint_cap);
        oclp_domain::delete_test_registration(domain_reg);
        clock::destroy_for_testing(clock);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test Helper Function Tests
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that create_test_package creates a valid test package.
    /// 
    /// Value: Ensures the test helper produces valid packages for other
    /// modules to use in their tests.
    #[test]
    fun test_create_test_package() {
        let mut ctx = tx_context::dummy();
        let domain_id = object::id_from_address(@0x123);
        
        let package = oclp_package::create_test_package(
            domain_id,
            string::utf8(b"Test Helper Package"),
            TEST_MERKLE_ROOT,
            &mut ctx
        );
        
        assert!(oclp_package::get_package_name(&package) == string::utf8(b"Test Helper Package"), 0);
        assert!(oclp_package::get_merkle_root(&package) == TEST_MERKLE_ROOT, 1);
        assert!(oclp_package::get_created_at(&package) == 0, 2); // Test packages have 0 timestamp
        assert!(oclp_package::get_oclp_package_version(&package) == 1, 3);
        
        oclp_package::delete(package);
    }

    /// Verifies that create_test_mint_cap creates a valid mint cap.
    /// 
    /// Value: Ensures the test helper produces valid mint caps for testing.
    #[test]
    fun test_create_test_mint_cap() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        
        let mint_cap = oclp_package::create_test_mint_cap(
            sender,
            60000,
            100,
            &mut ctx,
        );
        
        assert!(oclp_package::get_mint_count(&mint_cap) == 0, 0);
        assert!(oclp_package::get_last_mint_timestamp(&mint_cap) == 0, 1);
        
        oclp_package::delete_test_mint_cap(mint_cap);
    }

    /// Verifies that create_test_mint_cap_with_count creates a mint cap with preset values.
    /// 
    /// Value: Ensures the test helper can create mint caps in various states
    /// for testing rate limiting scenarios.
    #[test]
    fun test_create_test_mint_cap_with_count() {
        let mut ctx = tx_context::dummy();
        let sender = tx_context::sender(&ctx);
        
        let mint_cap = oclp_package::create_test_mint_cap_with_count(
            sender,
            30000,
            50000,
            200,
            75,
            &mut ctx,
        );
        
        assert!(oclp_package::get_mint_count(&mint_cap) == 75, 0);
        assert!(oclp_package::get_last_mint_timestamp(&mint_cap) == 50000, 1);
        
        oclp_package::delete_test_mint_cap(mint_cap);
    }
}
