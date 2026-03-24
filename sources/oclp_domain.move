/*
1. Create a domain
2. Optionally link a SuiNS
3. Optionally set a schema
4. Update domain properties (name, schema)
5. Add extra Admins
*/


module oclp::oclp_domain {
    use std::string::{Self, String};
    use sui::clock::Clock;
    use sui::event;
    use sui::table::{Self, Table};
    use sui::zklogin_verified_issuer::VerifiedIssuer;
    use suins::{ 
            suins::SuiNS,
            registry::Registry,
            domain,
        };

    const OCLP_DOMAIN_VERSION: u64 = 1;
    // ═══════════════════════════════════════════════════════════════════════
    // Error Codes
    // Wallet Errors < 100
    // Domain Errors >= 100 < 200
    // Package Minting Errors >= 200 < 300
    // ═══════════════════════════════════════════════════════════════════════

    const E_DOMAIN_WEB3NS_NOT_FOUND: u64 = 103;
    const E_DOMAIN_WEB3NS_EXPIRED: u64 = 104;
    const E_DOMAIN_WEB3NS_NOT_POINTING_TO_SENDER: u64 = 105;
    const E_DOMAIN_EMPTY_DOMAIN_NAME: u64 = 106;
    const E_DOMAIN_ADMIN_CAP_MISMATCH: u64 = 107;
    const E_DOMAIN_ALREADY_HAS_CHARTER: u64 = 108;
    const E_DOMAIN_INVALID_CHARTER_STORAGE_REF: u64 = 109;
    const E_DOMAIN_INVALID_CHARTER_HASH: u64 = 110;

    const E_WALLET_NOT_VERIFIED: u64 = 8;
    const E_WALLET_TOO_MANY_DOMAINS: u64 = 10;
    // ═══════════════════════════════════════════════════════════════════════
    // Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// Shared public domain record
    /// 
    /// This is the protocol-level primitive. Any call to OCLPPackage::mint
    /// and related calls will require a domain.
    public struct OCLPDomainRegistration has key, store {
        id: object::UID,
        domain_name: String,
        web3ns_name: Option<String>,
        web3ns_target_address: Option<address>, 
        verified_issuer_id: object::ID,
        domain_schema: Option<vector<u8>>,
        daily_mint_limit: u64,
        total_mint_cap: u64,
        mints_today: u64,
        last_mint_epoch: u64,
        total_mints: u64,
        oclp_domain_version: u64,
        charter_storage_ref: Option<vector<u8>>,
        charter_hash: Option<vector<u8>>
    }

// TODO: Move web3ns_name & web3ns_target_address out of protocol layer into a composed layer
// They are domain trust layers and should be managed by the domain


    public struct OCLPDomainCharter has key, store {
        id: object::UID,
        domain_id: object::ID,
        domain_name: String,
        charter_storage_ref: vector<u8>,
        charter_hash: vector<u8>,
        created_at: u64,
        oclp_domain_version: u64,
    }

    /// Owned - proves admin control over a domain
    public struct OCLPDomainAdminCap has key {
        id: object::UID,
        domain_id: object::ID,
        address: address,
        oclp_domain_version: u64,
    }

    /// Public registry of domain counts by wallet
    public struct OCLPDomainCreationRegistry has key {
        id: object::UID,
        domains_created: Table<address, u64>,
        oclp_domain_version: u64,
    }

    /// Configurable policy for domain creation limits
    public struct OCLPDomainPolicyConfig has key {
        id: object::UID,
        max_domains_unverified: u64,
        max_domains_verified: u64,
        default_daily_mint_limit_unverified: u64,
        default_total_mint_cap_unverified: u64,
        default_daily_mint_limit_verified: u64,
        default_total_mint_cap_verified: u64,
        oclp_domain_version: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════

    public struct OCLPDomainCreatedEvent has copy, drop {
        domain_id: object::ID,
        domain_name: String,
        web3ns_name: Option<String>,
        creator: address,
        oclp_domain_version: u64,
    }

    public struct OCLPDomainUpdatedEvent has copy, drop {
        domain_id: object::ID,
        domain_name: String,
        web3ns_name: Option<String>,
        updater: address,
        oclp_domain_version: u64,
    }

    public struct OCLPDomainSuinsLinkedEvent has copy, drop {
        domain_id: object::ID,
        web3ns_name: String,
        web3ns_target_address: address,
        linker: address,
        oclp_domain_version: u64,
    }

    public struct OCLPDomainCharterCreatedEvent has copy, drop {
        domain_id: object::ID,
        domain_name: String,
        charter_storage_ref: vector<u8>,
        charter_hash: vector<u8>,
        creator: address,
        oclp_domain_version: u64,
    }

    public struct OCLPDomainAdminAddedEvent has copy, drop {
        domain_id: object::ID,
        web3ns_name: Option<String>,
        admin_address: address,
        issuer_address: address,
        oclp_domain_version: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Init
    // ═══════════════════════════════════════════════════════════════════════

    fun init(ctx: &mut tx_context::TxContext) {
        let registry = OCLPDomainCreationRegistry {
            id: object::new(ctx),
            domains_created: table::new(ctx),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        let policy = OCLPDomainPolicyConfig {
            id: object::new(ctx),
            max_domains_unverified: 5,
            max_domains_verified: 50,
            default_daily_mint_limit_unverified: 5,
            default_total_mint_cap_unverified: 1000,
            default_daily_mint_limit_verified: 50,
            default_total_mint_cap_verified: 10000,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        transfer::share_object(registry);
        transfer::share_object(policy);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Core Domain Creation (Composability Primitives)
    // ═══════════════════════════════════════════════════════════════════════

    /// Create an unverified domain (Tier 1 - no SuiNS)
    ///
    /// # Arguments
    /// * `registry` - Domain creation registry for tracking counts
    /// * `policy` - Policy config for limits
    /// * `verified_issuer` - zkLogin VerifiedIssuer object
    /// * `domain_name` - Human-readable domain name
    /// * `domain_schema` - Optional Walrus blob ID for domain schema
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// The OCLPDomainAdminCap for the created domain
    ///
    /// # Aborts
    /// * `E_WALLET_NOT_VERIFIED` - If verified_issuer owner doesn't match sender
    /// * `E_DOMAIN_EMPTY_DOMAIN_NAME` - If domain_name is empty
    /// * `E_WALLET_TOO_MANY_DOMAINS` - If wallet has reached domain limit
    public fun create_domain(
        registry: &mut OCLPDomainCreationRegistry,
        policy: &OCLPDomainPolicyConfig,
        verified_issuer: &VerifiedIssuer,
        domain_name: String,
        domain_schema: Option<vector<u8>>,
        ctx: &mut tx_context::TxContext
    ): OCLPDomainAdminCap {
        let sender = tx_context::sender(ctx);

        // Verify zkLogin ownership
        assert!(
            sui::zklogin_verified_issuer::owner(verified_issuer) == sender,
            E_WALLET_NOT_VERIFIED
        );

        // Validate domain name
        assert!(string::length(&domain_name) > 0, E_DOMAIN_EMPTY_DOMAIN_NAME);

        // Check domain creation limit (unverified tier)
        let created = get_count(registry, sender);
        assert!(created < policy.max_domains_unverified, E_WALLET_TOO_MANY_DOMAINS);

        // Update creation count
        increment_count(registry, sender);

        // Create shared registration with unverified limits
        let registration = OCLPDomainRegistration {
            id: object::new(ctx),
            domain_name,
            web3ns_name: option::none(),
            web3ns_target_address: option::none(),
            verified_issuer_id: object::id(verified_issuer),
            domain_schema,
            daily_mint_limit: policy.default_daily_mint_limit_unverified,
            total_mint_cap: policy.default_total_mint_cap_unverified,
            mints_today: 0,
            last_mint_epoch: 0,
            total_mints: 0,
            charter_storage_ref: option::none(),
            charter_hash: option::none(),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        let domain_id = object::id(&registration);

        // Emit event for indexers
        event::emit(OCLPDomainCreatedEvent {
            domain_id,
            domain_name: registration.domain_name,
            web3ns_name: option::none(),
            creator: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });

        // Share the registration
        transfer::share_object(registration);

        // Return admin cap to caller
        let admin_cap = OCLPDomainAdminCap {
            id: object::new(ctx),
            domain_id,
            address: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        // Special case for first admin, they effectively issue the cap to themselves
        event::emit(OCLPDomainAdminAddedEvent {
            domain_id,
            admin_address: sender,
            web3ns_name: option::none(),
            issuer_address: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });

        admin_cap
    }

    /// Create a verified domain with SuiNS (Tier 2)
    ///
    /// Uses the SuiNS core registry to verify:
    /// 1. The name exists
    /// 2. The name is not expired
    /// 3. The name's target address matches the sender
    ///
    /// # Arguments
    /// * `registry` - Domain creation registry for tracking counts
    /// * `policy` - Policy config for limits
    /// * `verified_issuer` - zkLogin VerifiedIssuer object
    /// * `web3ns` - SuiNS shared object
    /// * `web3ns_name` - SuiNS name to verify and link
    /// * `domain_name` - Human-readable domain name (can differ from sui_ns_name)
    /// * `domain_schema` - Optional Walrus blob ID for domain schema
    /// * `clock` - Sui Clock for expiration checking
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// The OCLPDomainAdminCap for the created domain
    ///
    /// # Aborts
    /// * `E_WALLET_NOT_VERIFIED` - If verified_issuer owner doesn't match sender
    /// * `E_DOMAIN_EMPTY_DOMAIN_NAME` - If domain_name is empty
    /// * `E_DOMAIN_WEB3NS_NOT_FOUND` - If SuiNS name doesn't exist
    /// * `E_DOMAIN_WEB3NS_EXPIRED` - If SuiNS name has expired
    /// * `E_DOMAIN_WEB3NS_NOT_POINTING_TO_SENDER` - If SuiNS target address doesn't match sender
    /// * `E_WALLET_TOO_MANY_DOMAINS` - If wallet has reached domain limit
    public fun create_domain_with_web3ns(
        registry: &mut OCLPDomainCreationRegistry,
        policy: &OCLPDomainPolicyConfig,
        verified_issuer: &VerifiedIssuer,
        web3ns: &SuiNS,
        web3ns_name: String,
        domain_name: String,
        domain_schema: Option<vector<u8>>,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ): OCLPDomainAdminCap {
        let sender = tx_context::sender(ctx);

        // Verify zkLogin ownership
        assert!(
            sui::zklogin_verified_issuer::owner(verified_issuer) == sender,
            E_WALLET_NOT_VERIFIED
        );

        // Validate domain name
        assert!(string::length(&domain_name) > 0, E_DOMAIN_EMPTY_DOMAIN_NAME);

        // Verify SuiNS ownership
        let (web3ns_target_address) = verify_web3ns_ownership(web3ns, &web3ns_name, sender, clock);

        // Check domain creation limit (verified tier)
        let created = get_count(registry, sender);
        assert!(created < policy.max_domains_verified, E_WALLET_TOO_MANY_DOMAINS);

        // Update creation count
        increment_count(registry, sender);

        // Create shared registration with verified limits
        let registration = OCLPDomainRegistration {
            id: object::new(ctx),
            domain_name,
            web3ns_name: option::some(web3ns_name),
            web3ns_target_address: option::some(web3ns_target_address),
            verified_issuer_id: object::id(verified_issuer),
            domain_schema,
            daily_mint_limit: policy.default_daily_mint_limit_verified,
            total_mint_cap: policy.default_total_mint_cap_verified,
            mints_today: 0,
            last_mint_epoch: 0,
            total_mints: 0,
            charter_storage_ref: option::none(),
            charter_hash: option::none(),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        let domain_id = object::id(&registration);

        // Emit event for indexers
        event::emit(OCLPDomainCreatedEvent {
            domain_id,
            domain_name: registration.domain_name,
            web3ns_name: registration.web3ns_name,
            creator: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });

        // Share the registration
        transfer::share_object(registration);

        // Return admin cap to caller
        let admin_cap = OCLPDomainAdminCap {
            id: object::new(ctx),
            domain_id,
            address: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        // Special case for first admin, they effectively issue the cap to themselves
        event::emit(OCLPDomainAdminAddedEvent {
            domain_id,
            admin_address: sender,
            web3ns_name: option::none(),
            issuer_address: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });

        admin_cap
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Admin Functions (require OCLPDomainAdminCap)
    // ═══════════════════════════════════════════════════════════════════════

    /// Link SuiNS to an existing domain
    ///
    /// Upgrades an unverified domain to verified status by linking a SuiNS name.
    /// Also upgrades the mint limits to verified tier.
    ///
    /// # Arguments
    /// * `registration` - The domain registration to update
    /// * `admin_cap` - Admin capability proving ownership
    /// * `policy` - Policy config for verified limits
    /// * `web3ns` - SuiNS shared object
    /// * `web3ns_name` - SuiNS name to verify and link
    /// * `clock` - Sui Clock for expiration checking
    /// * `ctx` - Transaction context
    ///
    /// # Aborts
    /// * `E_DOMAIN_ADMIN_CAP_MISMATCH` - If admin_cap doesn't match registration
    /// * `E_DOMAIN_SUINSNOT_FOUND` - If SuiNS name doesn't exist
    /// * `E_DOMAIN_SUINSEXPIRED` - If SuiNS name has expired
    /// * `E_DOMAIN_SUINSNOT_POINTING_TO_SENDER` - If SuiNS target address doesn't match sender
    public fun link_web3ns(
        registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        policy: &OCLPDomainPolicyConfig,
        web3ns: &SuiNS,
        web3ns_name: String,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // Verify admin cap matches sender
        assert!(
            admin_cap.address == sender,
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );
    
        // Verify admin cap matches registration
        assert!(
            admin_cap.domain_id == object::id(registration),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Verify SuiNS ownership
        let web3ns_target_address = verify_web3ns_ownership(web3ns, &web3ns_name, sender, clock);

        // Update registration with SuiNS info
        registration.web3ns_name = option::some(web3ns_name);
        registration.web3ns_target_address = option::some(web3ns_target_address);

        // Upgrade to verified tier limits
        registration.daily_mint_limit = policy.default_daily_mint_limit_verified;
        registration.total_mint_cap = policy.default_total_mint_cap_verified;

        // Emit event
        event::emit(OCLPDomainSuinsLinkedEvent {
            domain_id: object::id(registration),
            web3ns_name,
            web3ns_target_address,
            linker: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });
    }

    /// Update the domain name
    ///
    /// # Arguments
    /// * `registration` - The domain registration to update
    /// * `admin_cap` - Admin capability proving ownership
    /// * `new_name` - New domain name
    /// * `ctx` - Transaction context
    ///
    /// # Aborts
    /// * `E_DOMAIN_ADMIN_CAP_MISMATCH` - If admin_cap doesn't match registration
    /// * `E_DOMAIN_EMPTY_DOMAIN_NAME` - If new_name is empty
    public fun update_domain_name(
        registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        new_name: String,
        ctx: &mut tx_context::TxContext
    ) {
    
        // Verify admin cap matches sender
        assert!(
            admin_cap.address == tx_context::sender(ctx),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Verify admin cap matches registration
        assert!(
            admin_cap.domain_id == object::id(registration),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Validate new name
        assert!(string::length(&new_name) > 0, E_DOMAIN_EMPTY_DOMAIN_NAME);

        // Update domain name
        registration.domain_name = new_name;

        // Emit event
        event::emit(OCLPDomainUpdatedEvent {
            domain_id: object::id(registration),
            domain_name: new_name,
            web3ns_name: registration.web3ns_name,
            updater: tx_context::sender(ctx),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });
    }

    /// Update the domain schema
    ///
    /// # Arguments
    /// * `registration` - The domain registration to update
    /// * `admin_cap` - Admin capability proving ownership
    /// * `new_schema` - New domain schema (Walrus blob ID)
    /// * `ctx` - Transaction context
    ///
    /// # Aborts
    /// * `E_DOMAIN_ADMIN_CAP_MISMATCH` - If admin_cap doesn't match registration
    public fun update_domain_schema(
        registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        new_schema: Option<vector<u8>>,
        ctx: &mut tx_context::TxContext
    ) {

        // Verify admin cap matches sender
        assert!(
            admin_cap.address == tx_context::sender(ctx),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Verify admin cap matches registration
        assert!(
            admin_cap.domain_id == object::id(registration),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Update domain schema
        registration.domain_schema = new_schema;

        // Emit event
        event::emit(OCLPDomainUpdatedEvent {
            domain_id: object::id(registration),
            domain_name: registration.domain_name,
            web3ns_name: registration.web3ns_name,
            updater: tx_context::sender(ctx),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });
    }

    public fun create_admin_cap_for(
        admin_cap: &OCLPDomainAdminCap,
        domain_id: object::ID,
        new_admin_address: address,
        ctx: &mut tx_context::TxContext,
    ) : OCLPDomainAdminCap {
        
        let sender = tx_context::sender(ctx);

        assert!(
            admin_cap.address == sender,
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        assert!(
            admin_cap.domain_id == domain_id,
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );


        let admin_cap = OCLPDomainAdminCap {
            id: object::new(ctx),
            domain_id,
            address: new_admin_address,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };
        
        event::emit(OCLPDomainAdminAddedEvent {
            domain_id,
            web3ns_name: option::none(),
            admin_address: new_admin_address,
            issuer_address: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });

        admin_cap
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Entry Points (Convenience Wrappers)
    // ═══════════════════════════════════════════════════════════════════════

    /// Create an unverified domain and transfer admin cap to sender
    #[allow(lint(self_transfer))]
    entry fun create_domain_to_sender(
        registry: &mut OCLPDomainCreationRegistry,
        policy: &OCLPDomainPolicyConfig,
        verified_issuer: &VerifiedIssuer,
        domain_name: String,
        domain_schema: Option<vector<u8>>,
        ctx: &mut tx_context::TxContext
    ) {
        let admin_cap = create_domain(
            registry,
            policy,
            verified_issuer,
            domain_name,
            domain_schema,
            ctx
        );
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Create a verified domain with SuiNS and transfer admin cap to sender
    #[allow(lint(self_transfer))]
    entry fun create_domain_with_web3ns_to_sender(
        registry: &mut OCLPDomainCreationRegistry,
        policy: &OCLPDomainPolicyConfig,
        verified_issuer: &VerifiedIssuer,
        web3ns: &SuiNS,
        web3ns_name: String,
        domain_name: String,
        domain_schema: Option<vector<u8>>,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ) {
        let admin_cap = create_domain_with_web3ns(
            registry,
            policy,
            verified_issuer,
            web3ns,
            web3ns_name,
            domain_name,
            domain_schema,
            clock,
            ctx
        );
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    /// Link SuiNS to an existing domain (entry point)
    entry fun link_web3ns_entry(
        registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        policy: &OCLPDomainPolicyConfig,
        web3ns: &SuiNS,
        web3ns_name: String,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ) {
        link_web3ns(registration, admin_cap, policy, web3ns, web3ns_name, clock, ctx);
    }

    /// Update domain name (entry point)
    entry fun update_domain_name_entry(
        registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        new_name: String,
        ctx: &mut tx_context::TxContext
    ) {
        update_domain_name(registration, admin_cap, new_name, ctx);
    }

    /// Update domain schema (entry point)
    entry fun update_domain_schema_entry(
        registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        new_schema: Option<vector<u8>>,
        ctx: &mut tx_context::TxContext
    ) {
        update_domain_schema(registration, admin_cap, new_schema, ctx);
    }

    /// Create a new admin cap for a domain and transfer it to a wallet (entry point)
    entry fun create_domain_admin_for_wallet(
        admin_cap: &OCLPDomainAdminCap,
        domain_id: object::ID,
        new_admin_address: address,
        ctx: &mut tx_context::TxContext,
    ) {
        let admin_cap = create_admin_cap_for(
            admin_cap, 
            domain_id, 
            new_admin_address, 
            ctx
        );

        transfer::transfer(admin_cap, new_admin_address);
    }

    /// Add a charter to an existing domain
    ///
    /// Creates an OCLPDomainCharter object containing a reference to a JSON document
    /// stored on Walrus. A domain can only have one charter.
    ///
    /// TODO: Add check for Walrus charter registration object ownership and blob IDs match
    ///
    /// # Arguments
    /// * `domain_registration` - The domain registration to attach the charter to
    /// * `admin_cap` - Admin capability proving ownership of the domain
    /// * `domain_name` - Human-readable domain name
    /// * `domain_id` - The object ID of the domain
    /// * `charter_storage_ref` - Walrus blob ID for the charter document (32 bytes)
    /// * `charter_hash` - Hash of the charter document (32 bytes)
    /// * `clock` - Sui Clock for timestamp
    /// * `ctx` - Transaction context
    ///
    /// # Aborts
    /// * `E_DOMAIN_ADMIN_CAP_MISMATCH` - If admin_cap doesn't match registration
    /// * `E_DOMAIN_ALREADY_HAS_CHARTER` - If domain already has a charter
    /// * `E_DOMAIN_INVALID_CHARTER_STORAGE_REF` - If charter_storage_ref length != 32
    /// * `E_DOMAIN_INVALID_CHARTER_HASH` - If charter_hash length != 32
    entry fun add_domain_charter(
        domain_registration: &mut OCLPDomainRegistration,
        admin_cap: &OCLPDomainAdminCap,
        domain_name: String,
        domain_id: object::ID,
        charter_storage_ref: vector<u8>,
        charter_hash: vector<u8>,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // Verify admin cap matches sender
        assert!(
            admin_cap.address == sender,
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Verify admin cap matches registration
        assert!(
            admin_cap.domain_id == object::id(domain_registration),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Verify domain ID matches registration
        assert!(
            domain_id == object::id(domain_registration),
            E_DOMAIN_ADMIN_CAP_MISMATCH
        );

        // Check that domain doesn't already have a charter
        assert!(
            domain_registration.charter_storage_ref.is_none(),
            E_DOMAIN_ALREADY_HAS_CHARTER
        );

        // Validate charter storage ref length (32 bytes)
        assert!(
            vector::length(&charter_storage_ref) == 32,
            E_DOMAIN_INVALID_CHARTER_STORAGE_REF
        );

        // Validate charter hash length (32 bytes)
        assert!(
            vector::length(&charter_hash) == 32,
            E_DOMAIN_INVALID_CHARTER_HASH
        );

        // Update registration with charter info
        domain_registration.charter_storage_ref = option::some(charter_storage_ref);
        domain_registration.charter_hash = option::some(charter_hash);

        // Create the charter object
        let charter = OCLPDomainCharter {
            id: object::new(ctx),
            domain_id,
            domain_name,
            charter_storage_ref,
            charter_hash,
            created_at: clock.timestamp_ms(),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        };

        // Emit event
        event::emit(OCLPDomainCharterCreatedEvent {
            domain_id,
            domain_name,
            charter_storage_ref,
            charter_hash,
            creator: sender,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        });

        // Transfer charter object to sender
        transfer::transfer(charter, sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Accessor Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Get the domain registration ID
    public fun get_id(registration: &OCLPDomainRegistration): object::ID {
        object::id(registration)
    }

    /// Get the domain name
    public fun get_domain_name(registration: &OCLPDomainRegistration): String {
        registration.domain_name
    }

    /// Get the SuiNS name (if any)
    public fun get_web3ns_name(registration: &OCLPDomainRegistration): Option<String> {
        registration.web3ns_name
    }

    /// Get the SuiNS target address (if any)
    public fun get_web3ns_target_address(registration: &OCLPDomainRegistration): Option<address> {
        registration.web3ns_target_address
    }

    /// Get the verified issuer ID
    public fun get_verified_issuer(registration: &OCLPDomainRegistration): object::ID {
        registration.verified_issuer_id
    }

    /// Get the domain schema (if any)
    public fun get_domain_schema(registration: &OCLPDomainRegistration): Option<vector<u8>> {
        registration.domain_schema
    }

    /// Get the daily mint limit
    public fun get_daily_mint_limit(registration: &OCLPDomainRegistration): u64 {
        registration.daily_mint_limit
    }

    /// Get the total mint cap
    public fun get_total_mint_cap(registration: &OCLPDomainRegistration): u64 {
        registration.total_mint_cap
    }

    /// Get mints today count
    public fun get_mints_today(registration: &OCLPDomainRegistration): u64 {
        registration.mints_today
    }

    /// Get last mint epoch
    public fun get_last_mint_epoch(registration: &OCLPDomainRegistration): u64 {
        registration.last_mint_epoch
    }

    /// Get total mints count
    public fun get_total_mints(registration: &OCLPDomainRegistration): u64 {
        registration.total_mints
    }

    /// Check if domain is verified (has SuiNS)
    public fun is_verified(registration: &OCLPDomainRegistration): bool {
        registration.web3ns_name.is_some()
    }

    /// Get the charter storage ref (if any)
    public fun get_charter_storage_ref(registration: &OCLPDomainRegistration): Option<vector<u8>> {
        registration.charter_storage_ref
    }

    /// Get the charter hash (if any)
    public fun get_charter_hash(registration: &OCLPDomainRegistration): Option<vector<u8>> {
        registration.charter_hash
    }

    /// Check if domain has a charter
    public fun has_charter(registration: &OCLPDomainRegistration): bool {
        registration.charter_storage_ref.is_some()
    }

    /// Get the OCLP domain version
    public fun get_oclp_domain_version(registration: &OCLPDomainRegistration): u64 {
        registration.oclp_domain_version
    }

    /// Get the domain ID from admin cap
    public fun get_admin_cap_domain_id(admin_cap: &OCLPDomainAdminCap): object::ID {
        admin_cap.domain_id
    }

    /// Get the OCLP domain version from admin cap
    public fun get_admin_cap_oclp_domain_version(admin_cap: &OCLPDomainAdminCap): u64 {
        admin_cap.oclp_domain_version
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Get domain count for a wallet
    fun get_count(registry: &OCLPDomainCreationRegistry, wallet: address): u64 {
        if (table::contains(&registry.domains_created, wallet)) {
            *table::borrow(&registry.domains_created, wallet)
        } else {
            0
        }
    }

    /// Increment domain count for a wallet
    fun increment_count(registry: &mut OCLPDomainCreationRegistry, wallet: address) {
        if (table::contains(&registry.domains_created, wallet)) {
            let count = table::borrow_mut(&mut registry.domains_created, wallet);
            *count = *count + 1;
        } else {
            table::add(&mut registry.domains_created, wallet, 1);
        }
    }

    /// Verify SuiNS ownership and return target address
    ///
    /// # Aborts
    /// * `E_DOMAIN_WEB3NS_NOT_FOUND` - If SuiNS name doesn't exist
    /// * `E_DOMAIN_WEB3NS_EXPIRED` - If SuiNS name has expired
    /// * `E_DOMAIN_WEB3NS_NOT_POINTING_TO_SENDER` - If SuiNS target address doesn't match sender
    fun verify_web3ns_ownership(
        web3ns: &SuiNS,
        web3ns_name: &String,
        sender: address,
        clock: &Clock
    ): address {
        // Look up the SuiNS name in the registry
        let mut optional = web3ns.registry<Registry>().lookup(domain::new(*web3ns_name));

        // Check that the name exists
        assert!(optional.is_some(), E_DOMAIN_WEB3NS_NOT_FOUND);

        let name_record = optional.extract();

        // Check that the name is not expired
        assert!(!name_record.has_expired(clock), E_DOMAIN_WEB3NS_EXPIRED);

        // Check that the name's target address exists
        assert!(name_record.target_address().is_some(), E_DOMAIN_WEB3NS_NOT_POINTING_TO_SENDER);

        // Check that the target address is the sender
        let target_address = name_record.target_address().extract();
        assert!(target_address == sender, E_DOMAIN_WEB3NS_NOT_POINTING_TO_SENDER);

        target_address
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test-only Functions
    // ═══════════════════════════════════════════════════════════════════════

    #[test_only]
    /// Create a test domain registration for unit tests
    public fun create_test_registration(
        domain_name: String,
        ctx: &mut tx_context::TxContext
    ): OCLPDomainRegistration {
        OCLPDomainRegistration {
            id: object::new(ctx),
            domain_name,
            web3ns_name: option::none(),
            web3ns_target_address: option::none(),
            verified_issuer_id: object::id_from_address(@0x0),
            domain_schema: option::none(),
            daily_mint_limit: 5,
            total_mint_cap: 100,
            mints_today: 0,
            last_mint_epoch: 0,
            total_mints: 0,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
            charter_storage_ref: option::none(),
            charter_hash: option::none(),
        }
    }

    #[test_only]
    /// Create a test admin cap for unit tests
    public fun create_test_admin_cap(
        domain_id: object::ID,
        address: address,
        ctx: &mut tx_context::TxContext
    ): OCLPDomainAdminCap {
        OCLPDomainAdminCap {
            id: object::new(ctx),
            domain_id,
            address,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        }
    }

    #[test_only]
    /// Create test registry for unit tests
    public fun create_test_registry(ctx: &mut tx_context::TxContext): OCLPDomainCreationRegistry {
        OCLPDomainCreationRegistry {
            id: object::new(ctx),
            domains_created: table::new(ctx),
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        }
    }

    #[test_only]
    /// Create test policy for unit tests
    public fun create_test_policy(ctx: &mut tx_context::TxContext): OCLPDomainPolicyConfig {
        OCLPDomainPolicyConfig {
            id: object::new(ctx),
            max_domains_unverified: 10,
            max_domains_verified: 100,
            default_daily_mint_limit_unverified: 5,
            default_total_mint_cap_unverified: 100,
            default_daily_mint_limit_verified: 50,
            default_total_mint_cap_verified: 10000,
            oclp_domain_version: OCLP_DOMAIN_VERSION,
        }
    }

    #[test_only]
    /// Delete test registration
    public fun delete_test_registration(registration: OCLPDomainRegistration) {
        let OCLPDomainRegistration {
            id,
            domain_name: _,
            web3ns_name: _,
            web3ns_target_address: _,
            verified_issuer_id: _,
            domain_schema: _,
            daily_mint_limit: _,
            total_mint_cap: _,
            mints_today: _,
            last_mint_epoch: _,
            total_mints: _,
            oclp_domain_version: _,
            charter_storage_ref: _,
            charter_hash: _,
        } = registration;
        object::delete(id);
    }

    #[test_only]
    /// Delete test admin cap
    public fun delete_test_admin_cap(admin_cap: OCLPDomainAdminCap) {
        let OCLPDomainAdminCap { id, domain_id: _, address: _, oclp_domain_version: _ } = admin_cap;
        object::delete(id);
    }

    #[test_only]
    /// Delete test registry
    public fun delete_test_registry(registry: OCLPDomainCreationRegistry) {
        let OCLPDomainCreationRegistry { id, domains_created, oclp_domain_version: _ } = registry;
        table::drop(domains_created);
        object::delete(id);
    }

    #[test_only]
    /// Delete test policy
    public fun delete_test_policy(policy: OCLPDomainPolicyConfig) {
        let OCLPDomainPolicyConfig {
            id,
            max_domains_unverified: _,
            max_domains_verified: _,
            default_daily_mint_limit_unverified: _,
            default_total_mint_cap_unverified: _,
            default_daily_mint_limit_verified: _,
            default_total_mint_cap_verified: _,
            oclp_domain_version: _,
        } = policy;
        object::delete(id);
    }
}
