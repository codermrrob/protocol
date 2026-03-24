/// Unit tests for the OCLP Domain module.
/// 
/// These tests verify the core functionality of domain registration management,
/// including creation, updates, and access control via the capability pattern.
/// 
/// Note: Tests for `create_domain` and `create_domain_with_suins` require
/// zkLogin VerifiedIssuer and SuiNS mocking which is not feasible in unit tests.
/// Those flows should be tested via integration tests or on testnet.
#[test_only]
module oclp::oclp_domain_tests {
    use std::string;
    use oclp::oclp_domain::{
        Self,
        OCLPDomainRegistration,
        OCLPDomainAdminCap,
        OCLPDomainCreationRegistry,
        OCLPDomainPolicyConfig,
    };

    // ═══════════════════════════════════════════════════════════════════════
    // Test Helper Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Creates a test environment with registry and policy objects.
    /// Use with `teardown_test_environment` to ensure proper cleanup.
    fun setup_test_environment(ctx: &mut tx_context::TxContext): (
        OCLPDomainCreationRegistry,
        OCLPDomainPolicyConfig
    ) {
        let registry = oclp_domain::create_test_registry(ctx);
        let policy = oclp_domain::create_test_policy(ctx);
        (registry, policy)
    }

    /// Cleans up test environment objects to prevent resource leaks.
    fun teardown_test_environment(
        registry: OCLPDomainCreationRegistry,
        policy: OCLPDomainPolicyConfig
    ) {
        oclp_domain::delete_test_registry(registry);
        oclp_domain::delete_test_policy(policy);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Registration Creation Tests
    // 
    // These tests verify that test helper functions correctly initialize
    // domain objects with expected default values. This ensures the test
    // infrastructure itself is reliable before testing business logic.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that `create_test_registration` initializes all fields correctly.
    /// 
    /// Value: Ensures the test helper produces valid domain registrations with
    /// expected defaults (unverified tier limits, no SuiNS, zero counters).
    /// This is foundational - if test objects are malformed, all other tests
    /// become unreliable.
    #[test]
    fun test_create_test_registration() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);

        assert!(oclp_domain::get_domain_name(&registration) == domain_name, 0);
        assert!(oclp_domain::get_suins_name(&registration).is_none(), 1);
        assert!(oclp_domain::get_suins_target_address(&registration).is_none(), 2);
        assert!(oclp_domain::get_domain_schema(&registration).is_none(), 3);
        assert!(oclp_domain::get_daily_mint_limit(&registration) == 5, 4);
        assert!(oclp_domain::get_total_mint_cap(&registration) == 100, 5);
        assert!(oclp_domain::get_mints_today(&registration) == 0, 6);
        assert!(oclp_domain::get_last_mint_epoch(&registration) == 0, 7);
        assert!(oclp_domain::get_total_mints(&registration) == 0, 8);
        assert!(!oclp_domain::is_verified(&registration), 9);
        assert!(oclp_domain::get_oclp_domain_version(&registration) == 1, 10);

        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that `create_test_admin_cap` correctly links to a domain.
    /// 
    /// Value: The admin cap's `domain_id` must match the registration it
    /// controls. This linkage is the foundation of the capability-based
    /// access control system.
    #[test]
    fun test_create_test_admin_cap() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        assert!(oclp_domain::get_admin_cap_domain_id(&admin_cap) == domain_id, 0);
        assert!(oclp_domain::get_admin_cap_oclp_domain_version(&admin_cap) == 1, 1);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies registry creation and deletion without errors.
    /// 
    /// Value: Ensures the registry (which tracks domain counts per wallet)
    /// can be created and properly cleaned up, preventing Table resource leaks.
    #[test]
    fun test_create_test_registry() {
        let mut ctx = tx_context::dummy();

        let registry = oclp_domain::create_test_registry(&mut ctx);

        oclp_domain::delete_test_registry(registry);
    }

    /// Verifies policy creation and deletion without errors.
    /// 
    /// Value: Ensures the policy config (which defines tier limits) can be
    /// created and cleaned up properly.
    #[test]
    fun test_create_test_policy() {
        let mut ctx = tx_context::dummy();

        let policy = oclp_domain::create_test_policy(&mut ctx);

        oclp_domain::delete_test_policy(policy);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Update Domain Name Tests
    // 
    // These tests verify the `update_domain_name` function which allows
    // domain administrators to change their domain's display name. The
    // capability pattern ensures only authorized parties can make changes.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that a domain name can be updated with a valid admin cap.
    /// 
    /// Value: Confirms the happy path - domain owners can rebrand or correct
    /// their domain name after creation. This is essential for domain
    /// lifecycle management.
    #[test]
    fun test_update_domain_name_success() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"original-domain");
        let new_name = string::utf8(b"updated-domain");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        oclp_domain::update_domain_name(&mut registration, &admin_cap, new_name, &mut ctx);

        assert!(oclp_domain::get_domain_name(&registration) == new_name, 0);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that an admin cap for a different domain cannot update this domain.
    /// 
    /// Value: Critical security test. The capability pattern only works if
    /// capabilities are domain-specific. Without this check, any admin cap
    /// holder could modify any domain, breaking the trust model entirely.
    #[test]
    #[expected_failure(abort_code = oclp::oclp_domain::E_DOMAIN_ADMIN_CAP_MISMATCH)]
    fun test_update_domain_name_wrong_admin_cap() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let new_name = string::utf8(b"updated-domain");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        let wrong_domain_id = object::id_from_address(@0x123);
        let wrong_admin_cap = oclp_domain::create_test_admin_cap(wrong_domain_id, @0x0, &mut ctx);

        oclp_domain::update_domain_name(&mut registration, &wrong_admin_cap, new_name, &mut ctx);

        oclp_domain::delete_test_admin_cap(wrong_admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that empty domain names are rejected.
    /// 
    /// Value: Data integrity check. Empty names would create unusable domains
    /// and break UI/indexer assumptions. This validation prevents garbage data
    /// from entering the system.
    #[test]
    #[expected_failure(abort_code = oclp::oclp_domain::E_DOMAIN_EMPTY_DOMAIN_NAME)]
    fun test_update_domain_name_empty_name() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let empty_name = string::utf8(b"");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        oclp_domain::update_domain_name(&mut registration, &admin_cap, empty_name, &mut ctx);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Update Domain Schema Tests
    // 
    // These tests verify the `update_domain_schema` function which allows
    // domain administrators to set or update the Walrus blob ID pointing to
    // their domain's JSON Schema definition. The schema enables machine-readable
    // domain discovery and interface definitions.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that a domain schema can be set with a valid admin cap.
    /// 
    /// Value: Confirms domains can be upgraded with schema definitions after
    /// creation. This supports iterative domain development where the schema
    /// may not be ready at domain creation time.
    #[test]
    fun test_update_domain_schema_success() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let new_schema = option::some(b"walrus_blob_id_12345");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        assert!(oclp_domain::get_domain_schema(&registration).is_none(), 0);

        oclp_domain::update_domain_schema(&mut registration, &admin_cap, new_schema, &mut ctx);

        assert!(oclp_domain::get_domain_schema(&registration).is_some(), 1);
        assert!(*oclp_domain::get_domain_schema(&registration).borrow() == b"walrus_blob_id_12345", 2);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that a domain schema can be cleared (set to None).
    /// 
    /// Value: Supports schema deprecation or temporary removal. Domain owners
    /// may need to remove a broken schema while preparing a replacement,
    /// rather than being forced to keep invalid data.
    #[test]
    fun test_update_domain_schema_to_none() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let schema = option::some(b"walrus_blob_id_12345");
        oclp_domain::update_domain_schema(&mut registration, &admin_cap, schema, &mut ctx);
        assert!(oclp_domain::get_domain_schema(&registration).is_some(), 0);

        oclp_domain::update_domain_schema(&mut registration, &admin_cap, option::none(), &mut ctx);
        assert!(oclp_domain::get_domain_schema(&registration).is_none(), 1);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that an admin cap for a different domain cannot update schema.
    /// 
    /// Value: Security test ensuring capability isolation extends to schema
    /// updates. Prevents attackers from injecting malicious schema definitions
    /// into domains they don't control.
    #[test]
    #[expected_failure(abort_code = oclp::oclp_domain::E_DOMAIN_ADMIN_CAP_MISMATCH)]
    fun test_update_domain_schema_wrong_admin_cap() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let new_schema = option::some(b"walrus_blob_id_12345");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        
        let wrong_domain_id = object::id_from_address(@0x456);
        let wrong_admin_cap = oclp_domain::create_test_admin_cap(wrong_domain_id, @0x0, &mut ctx);

        oclp_domain::update_domain_schema(&mut registration, &wrong_admin_cap, new_schema, &mut ctx);

        oclp_domain::delete_test_admin_cap(wrong_admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Accessor Function Tests
    // 
    // These tests verify the public getter functions return correct values.
    // Accessors are the public API for reading domain state - they must be
    // reliable for indexers, UIs, and other contracts to function correctly.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that `is_verified` returns false for domains without SuiNS.
    /// 
    /// Value: The verified/unverified distinction drives tier-based limits.
    /// Incorrect verification status would grant wrong mint limits and
    /// misrepresent domain trust level to users.
    #[test]
    fun test_is_verified_false_for_unverified_domain() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"unverified-domain");

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);

        assert!(!oclp_domain::is_verified(&registration), 0);

        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that `get_id` returns a valid, non-zero object ID.
    /// 
    /// Value: Object IDs are used for cross-referencing (admin cap linkage,
    /// event emission, external indexing). A zero or invalid ID would break
    /// these relationships.
    #[test]
    fun test_get_id_returns_valid_id() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let id = oclp_domain::get_id(&registration);

        assert!(id != object::id_from_address(@0x0), 0);

        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that admin cap's domain_id accessor matches the registration.
    /// 
    /// Value: Confirms the bidirectional relationship between admin caps and
    /// registrations is correctly queryable. Essential for UIs that need to
    /// display which domains a user can administer.
    #[test]
    fun test_admin_cap_domain_id_matches_registration() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        assert!(oclp_domain::get_admin_cap_domain_id(&admin_cap) == oclp_domain::get_id(&registration), 0);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Multiple Updates Tests
    // 
    // These tests verify that domain state can be modified multiple times
    // and that different fields can be updated independently. This ensures
    // the update functions don't have unintended side effects.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that domain name can be updated multiple times in sequence.
    /// 
    /// Value: Ensures no hidden state corruption from repeated updates.
    /// Domain owners may rebrand multiple times over a domain's lifetime -
    /// each update must cleanly replace the previous value.
    #[test]
    fun test_multiple_domain_name_updates() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"original");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let name1 = string::utf8(b"first-update");
        oclp_domain::update_domain_name(&mut registration, &admin_cap, name1, &mut ctx);
        assert!(oclp_domain::get_domain_name(&registration) == name1, 0);

        let name2 = string::utf8(b"second-update");
        oclp_domain::update_domain_name(&mut registration, &admin_cap, name2, &mut ctx);
        assert!(oclp_domain::get_domain_name(&registration) == name2, 1);

        let name3 = string::utf8(b"third-update");
        oclp_domain::update_domain_name(&mut registration, &admin_cap, name3, &mut ctx);
        assert!(oclp_domain::get_domain_name(&registration) == name3, 2);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that name and schema can be updated independently.
    /// 
    /// Value: Ensures field updates are isolated - updating name shouldn't
    /// affect schema and vice versa. This is important for partial updates
    /// where only one field needs to change.
    #[test]
    fun test_update_both_name_and_schema() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"original");

        let mut registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let new_name = string::utf8(b"new-name");
        oclp_domain::update_domain_name(&mut registration, &admin_cap, new_name, &mut ctx);

        let new_schema = option::some(b"schema_blob_id");
        oclp_domain::update_domain_schema(&mut registration, &admin_cap, new_schema, &mut ctx);

        assert!(oclp_domain::get_domain_name(&registration) == new_name, 0);
        assert!(oclp_domain::get_domain_schema(&registration).is_some(), 1);

        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Create Admin Cap For Tests
    // 
    // These tests verify the `create_admin_cap_for` function which allows
    // existing domain administrators to mint new admin capabilities for
    // additional wallets, enabling multi-admin domain management.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that an admin can create a new admin cap for another address.
    /// 
    /// Value: Confirms the happy path - domain owners can delegate admin
    /// privileges to other wallets. Essential for team-managed domains.
    #[test]
    fun test_create_admin_cap_for_success() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let new_admin_address = @0x999;

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let new_admin_cap = oclp_domain::create_admin_cap_for(
            &admin_cap,
            domain_id,
            new_admin_address,
            &mut ctx
        );

        assert!(oclp_domain::get_admin_cap_domain_id(&new_admin_cap) == domain_id, 0);

        oclp_domain::delete_test_admin_cap(new_admin_cap);
        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that the new admin cap is linked to the correct domain.
    /// 
    /// Value: Ensures newly minted admin caps correctly reference the
    /// domain they control, maintaining the capability-domain linkage.
    #[test]
    fun test_create_admin_cap_for_correct_domain_linkage() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let new_admin_address = @0x888;

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let new_admin_cap = oclp_domain::create_admin_cap_for(
            &admin_cap,
            domain_id,
            new_admin_address,
            &mut ctx
        );

        assert!(
            oclp_domain::get_admin_cap_domain_id(&new_admin_cap) == oclp_domain::get_id(&registration),
            0
        );

        oclp_domain::delete_test_admin_cap(new_admin_cap);
        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that an admin cap for a different domain cannot create caps.
    /// 
    /// Value: Critical security test. Prevents cross-domain privilege
    /// escalation where an admin of domain A tries to create admins for domain B.
    #[test]
    #[expected_failure(abort_code = oclp::oclp_domain::E_DOMAIN_ADMIN_CAP_MISMATCH)]
    fun test_create_admin_cap_for_wrong_domain_id() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");
        let new_admin_address = @0x777;

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let wrong_domain_id = object::id_from_address(@0x123);

        let new_admin_cap = oclp_domain::create_admin_cap_for(
            &admin_cap,
            wrong_domain_id,
            new_admin_address,
            &mut ctx
        );

        oclp_domain::delete_test_admin_cap(new_admin_cap);
        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    /// Verifies that multiple admin caps can be created for different addresses.
    /// 
    /// Value: Confirms that domain administration can be distributed across
    /// multiple wallets, supporting team-based domain management workflows.
    #[test]
    fun test_create_multiple_admin_caps() {
        let mut ctx = tx_context::dummy();
        let domain_name = string::utf8(b"test-domain");

        let registration = oclp_domain::create_test_registration(domain_name, &mut ctx);
        let domain_id = oclp_domain::get_id(&registration);
        let admin_cap = oclp_domain::create_test_admin_cap(domain_id, @0x0, &mut ctx);

        let admin_cap_2 = oclp_domain::create_admin_cap_for(
            &admin_cap,
            domain_id,
            @0x222,
            &mut ctx
        );

        let admin_cap_3 = oclp_domain::create_admin_cap_for(
            &admin_cap,
            domain_id,
            @0x333,
            &mut ctx
        );

        assert!(oclp_domain::get_admin_cap_domain_id(&admin_cap_2) == domain_id, 0);
        assert!(oclp_domain::get_admin_cap_domain_id(&admin_cap_3) == domain_id, 1);

        oclp_domain::delete_test_admin_cap(admin_cap_3);
        oclp_domain::delete_test_admin_cap(admin_cap_2);
        oclp_domain::delete_test_admin_cap(admin_cap);
        oclp_domain::delete_test_registration(registration);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test Environment Setup/Teardown Tests
    // 
    // Meta-tests that verify the test helper infrastructure works correctly.
    // ═══════════════════════════════════════════════════════════════════════

    /// Verifies that the test environment setup and teardown helpers work.
    /// 
    /// Value: Ensures the test infrastructure for future tests (that may need
    /// registry and policy objects) is functional. Catches resource leak bugs
    /// in the helper functions themselves.
    #[test]
    fun test_setup_and_teardown_environment() {
        let mut ctx = tx_context::dummy();

        let (registry, policy) = setup_test_environment(&mut ctx);

        teardown_test_environment(registry, policy);
    }
}
