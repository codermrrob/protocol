#[test_only]
module oclp::oclp_package_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use oclp::oclp_package::{Self, OCLPPackage};

    // ═══════════════════════════════════════════════════════════════════════
    // Test Constants
    // ═══════════════════════════════════════════════════════════════════════

    const TEST_SENDER: address = @0xCAFE;

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

    fun create_test_clock(scenario: &mut test_scenario::Scenario): clock::Clock {
        let ctx = test_scenario::ctx(scenario);
        clock::create_for_testing(ctx)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Mint Tests
    // ═══════════════════════════════════════════════════════════════════════

    #[test]
    fun test_mint_success() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        // First transaction: mint the package
        {
            let mut clock = create_test_clock(&mut scenario);
            clock::set_for_testing(&mut clock, 1000); // Set timestamp to 1000ms
            
            let package = oclp_package::mint(
                string::utf8(b"Test Package"),
                61, // Blake2b-256
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify package fields
            assert!(oclp_package::get_package_name(&package) == string::utf8(b"Test Package"), 0);
            assert!(oclp_package::get_merkle_integrity_algo(&package) == 61, 1);
            assert!(oclp_package::get_merkle_root(&package) == TEST_MERKLE_ROOT, 2);
            assert!(oclp_package::get_created_at(&package) == 1000, 3);
            assert!(oclp_package::get_package_storage_ref(&package) == b"package_blob_id", 4);
            assert!(oclp_package::get_manifest_version(&package) == string::utf8(b"1.4"), 5);
            assert!(oclp_package::get_manifest_integrity_algo(&package) == 61, 6);
            assert!(oclp_package::get_manifest_hash(&package) == TEST_MANIFEST_HASH, 7);
            assert!(oclp_package::get_manifest_storage_ref(&package) == b"manifest_blob_id", 8);
            assert!(option::is_none(&oclp_package::get_parent_manifest_id(&package)), 9);
            
            // Transfer to sender for cleanup
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_mint_to_sender() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        // First transaction: mint to sender
        {
            let mut clock = create_test_clock(&mut scenario);
            clock::set_for_testing(&mut clock, 2000);
            
            oclp_package::mint_to_sender(
                string::utf8(b"Direct Mint Package"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
        };
        
        // Second transaction: verify sender received the package
        test_scenario::next_tx(&mut scenario, TEST_SENDER);
        {
            let package = test_scenario::take_from_sender<OCLPPackage>(&scenario);
            
            assert!(oclp_package::get_package_name(&package) == string::utf8(b"Direct Mint Package"), 0);
            assert!(oclp_package::get_created_at(&package) == 2000, 1);
            
            test_scenario::return_to_sender(&scenario, package);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_mint_with_parent_manifest() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        // Create a fake parent ID for testing
        let parent_id = object::id_from_address(@0x123);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b"Child Package"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::some(parent_id),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify parent is set
            let parent_opt = oclp_package::get_parent_manifest_id(&package);
            assert!(option::is_some(&parent_opt), 0);
            assert!(*option::borrow(&parent_opt) == parent_id, 1);
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Validation Tests
    // ═══════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = oclp_package::E_EMPTY_PACKAGE_NAME)]
    fun test_mint_fails_empty_name() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b""), // Empty name - should fail
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = oclp_package::E_INVALID_MERKLE_ROOT_LENGTH)]
    fun test_mint_fails_short_merkle_root() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b"Test Package"),
                61,
                vector[0x01, 0x02, 0x03], // Only 3 bytes - should fail
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = oclp_package::E_INVALID_MERKLE_ROOT_LENGTH)]
    fun test_mint_fails_long_merkle_root() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            // 33 bytes - too long
            let long_hash = vector[
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
                0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
                0x21
            ];
            
            let package = oclp_package::mint(
                string::utf8(b"Test Package"),
                61,
                long_hash,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = oclp_package::E_INVALID_MANIFEST_HASH_LENGTH)]
    fun test_mint_fails_invalid_manifest_hash() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b"Test Package"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                vector[0x01, 0x02], // Only 2 bytes - should fail
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Delete Tests
    // ═══════════════════════════════════════════════════════════════════════

    #[test]
    fun test_delete() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b"Package to Delete"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Delete the package
            oclp_package::delete(package);
            
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_destroy_entry() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        // First transaction: mint
        {
            let clock = create_test_clock(&mut scenario);
            
            oclp_package::mint_to_sender(
                string::utf8(b"Package to Destroy"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
        };
        
        // Second transaction: destroy via entry function
        test_scenario::next_tx(&mut scenario, TEST_SENDER);
        {
            let package = test_scenario::take_from_sender<OCLPPackage>(&scenario);
            oclp_package::destroy(package);
        };
        
        // Verify package no longer exists
        test_scenario::next_tx(&mut scenario, TEST_SENDER);
        {
            assert!(!test_scenario::has_most_recent_for_sender<OCLPPackage>(&scenario), 0);
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Accessor Tests
    // ═══════════════════════════════════════════════════════════════════════

    #[test]
    fun test_get_manifest() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b"Test Package"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.5"),
                62, // Different algo for manifest
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Test get_manifest returns full struct
            let manifest = oclp_package::get_manifest(&package);
            
            // Manifest should be copyable, we got it by value
            let _ = manifest;
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_get_id() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let clock = create_test_clock(&mut scenario);
            
            let package = oclp_package::mint(
                string::utf8(b"Test Package"),
                61,
                TEST_MERKLE_ROOT,
                b"package_blob_id",
                string::utf8(b"1.4"),
                61,
                TEST_MANIFEST_HASH,
                b"manifest_blob_id",
                option::none(),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify get_id matches object::id
            let id_from_accessor = oclp_package::get_id(&package);
            let id_from_object = object::id(&package);
            assert!(id_from_accessor == id_from_object, 0);
            
            sui::transfer::public_transfer(package, TEST_SENDER);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test Helper Function Tests
    // ═══════════════════════════════════════════════════════════════════════

    #[test]
    fun test_create_test_package() {
        let mut scenario = test_scenario::begin(TEST_SENDER);
        
        {
            let package = oclp_package::create_test_package(
                string::utf8(b"Test Helper Package"),
                TEST_MERKLE_ROOT,
                test_scenario::ctx(&mut scenario)
            );
            
            assert!(oclp_package::get_package_name(&package) == string::utf8(b"Test Helper Package"), 0);
            assert!(oclp_package::get_merkle_root(&package) == TEST_MERKLE_ROOT, 1);
            assert!(oclp_package::get_created_at(&package) == 0, 2); // Test packages have 0 timestamp
            
            sui::transfer::public_transfer(package, TEST_SENDER);
        };
        
        test_scenario::end(scenario);
    }
}
