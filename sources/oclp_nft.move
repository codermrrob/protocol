module oclp::oclp_package {
    use std::string;
    use sui::clock::Clock;
    use sui::event;
    use sui::table::{Self, Table};
    use sui::zklogin_verified_issuer::VerifiedIssuer;

    const OCLP_PACKAGE_VERSION: u64 = 1;

    // ═══════════════════════════════════════════════════════════════════════
    // Error Codes
    // Wallet Errors < 100
    // Domain Errors >= 100 < 200
    // Package Errors >= 200 < 300
    // ═══════════════════════════════════════════════════════════════════════
    
    const E_PACKAGE_INVALID_MERKLE_ROOT_LENGTH: u64 = 201;
    const E_PACKAGE_INVALID_MANIFEST_HASH_LENGTH: u64 = 202;
    const E_PACKAGE_EMPTY_PACKAGE_NAME: u64 = 203;
    const E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS: u64 = 205;

    const E_WALLET_INVALID_MINTCAP: u64 = 7;
    const E_WALLET_NOT_VERIFIED: u64 = 8;
    const E_WALLET_MINTCAP_EXISTS: u64 = 10;

    // ═══════════════════════════════════════════════════════════════════════
    // Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// Embedded manifest metadata
    public struct OCLPManifest has store, drop, copy {
        manifest_version: string::String,
        manifest_integrity_algo: u8,
        manifest_hash: vector<u8>,
        manifest_storage_blob_ref: vector<u8>,
        oclp_package_version: u64,
    }

    /// The OCLP Package NFT - represents cryptographically verified
    /// provenance of a content package.
    /// 
    /// This is the protocol-level primitive. Domain contracts create
    /// wrapper NFTs that reference this by ID for domain-specific
    /// discovery while maintaining protocol-level interoperability.
    public struct OCLPPackage has key, store {
        id: object::UID,
        domain_id: object::ID,    
        content_package_name: string::String,
        merkle_integrity_algo: u8,
        merkle_root: vector<u8>,
        created_at: u64,
        package_storage_blob_ref: vector<u8>,
        manifest: OCLPManifest,
        oclp_package_version: u64,
    }

    /// Configurable policy for minting limits
    public struct OCLPMintPolicyConfig has key {
        id: object::UID,
        cooldown_period: u64,
        total_mint_cap: u64,
        oclp_package_version: u64,
    }

    /// Mint Cap - proves permission & capability to mint a package
    public struct OCLPMintCap has key {
        id: object::UID,
        minter: address,
        cooldown_period: u64,
        last_mint_timestamp: u64,
        verified_issuer_id: object::ID,
        total_mint_cap: u64,
        mint_count: u64,
        oclp_package_version: u64,
    }

    public struct OCLPMintCapRegistry has key {
        id: object::UID,
        mint_cap_wallets: Table<address, bool>,
        oclp_package_version: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════

    /// Event emitted when an OCLP Package is minted
    public struct OCLPMintCompletedEvent has copy, drop {
        package_id: object::ID,
        minter: address,
        content_package_name: string::String,
        merkle_root: vector<u8>,
        minted_at_ms: u64,
        oclp_package_version: u64,
    }

    /// MintCap event
    public struct OCLPMintCapCreatedEvent has copy, drop {
        mint_cap_id: object::ID,
        minter: address,
        cooldown_period: u64,
        verified_issuer_id: object::ID,
        total_mint_cap: u64,
        oclp_package_version: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Init
    // ═══════════════════════════════════════════════════════════════════════

    fun init(ctx: &mut tx_context::TxContext) {
        let registry = OCLPMintCapRegistry {
            id: object::new(ctx),
            mint_cap_wallets: table::new(ctx),
            oclp_package_version: OCLP_PACKAGE_VERSION,
        };

        let policy = OCLPMintPolicyConfig {
            id: object::new(ctx),
            cooldown_period: 60000,
            total_mint_cap: 5000,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        };
        

        transfer::share_object(registry);
        transfer::share_object(policy);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Core Mint Cap Creation (Composability Primitive)
    // ═══════════════════════════════════════════════════════════════════════

    public fun create_mint_cap(
        registry: &mut Table<address, bool>,
        policy: &OCLPMintPolicyConfig,
        verified_issuer: &VerifiedIssuer,
        clock: &Clock,
        ctx: &mut tx_context::TxContext,
    ): OCLPMintCap {
        
        let sender = tx_context::sender(ctx);
        
        // Verify zkLogin ownership
        assert!(
            sui::zklogin_verified_issuer::owner(verified_issuer) == sender,
            E_WALLET_NOT_VERIFIED
        );

        let mintcap_exists = table::contains(registry, sender);
        assert!(!mintcap_exists, E_WALLET_MINTCAP_EXISTS);

        let verified_issuer_id = object::id(verified_issuer);

        let mintcap = OCLPMintCap {
            id : object::new(ctx),
            minter: sender,
            cooldown_period: policy.cooldown_period,
            last_mint_timestamp: clock.timestamp_ms(),
            verified_issuer_id: verified_issuer_id,
            total_mint_cap: policy.total_mint_cap,
            mint_count: 0,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        };

        table::add(registry, sender, true);

        event::emit(OCLPMintCapCreatedEvent {
            mint_cap_id : object::id(&mintcap),
            minter : sender,
            cooldown_period : policy.cooldown_period,
            verified_issuer_id : verified_issuer_id,
            total_mint_cap : policy.total_mint_cap,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        });

        mintcap
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Core Minting (Composability Primitive)
    // ═══════════════════════════════════════════════════════════════════════

    /// Mint and return an OCLPPackage
    /// 
    /// This is the primary composability entry point. Domain contracts call
    /// this to receive an OCLPPackage, then create their own NFT that is
    /// the owner of the OCLPPackage object. The dependency_merkle_roots
    /// parameter is limited to approx 500 hashes.
    ///
    /// # Returns
    /// The minted OCLPPackage, owned by the calling context
    public fun mint(
        domain_registration: &oclp::oclp_domain::OCLPDomainRegistration,
        content_package_name: string::String,
        merkle_integrity_algo: u8,
        merkle_root: vector<u8>,
        package_storage_blob_ref: vector<u8>,
        manifest_version: string::String,
        manifest_integrity_algo: u8,
        manifest_hash: vector<u8>,
        manifest_storage_blob_ref: vector<u8>,
        dependency_merkle_roots: vector<vector<u8>>,
        clock: &Clock,
        mint_cap: &mut OCLPMintCap,
        ctx: &mut tx_context::TxContext
    ): OCLPPackage {
        let sender = tx_context::sender(ctx);
        
        assert!(
            mint_cap.minter == sender,
            E_WALLET_INVALID_MINTCAP
        );

        assert!(
            mint_cap.last_mint_timestamp + mint_cap.cooldown_period < clock.timestamp_ms(),
            E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS
        );

        assert!(
            mint_cap.mint_count < mint_cap.total_mint_cap,
            E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS
        );

        assert!(
            (oclp::oclp_domain::get_mints_today(domain_registration) < oclp::oclp_domain::get_daily_mint_limit(domain_registration)) && 
            (oclp::oclp_domain::get_total_mints(domain_registration) < oclp::oclp_domain::get_total_mint_cap(domain_registration)),
            E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS
        );

        assert!(
            string::length(&content_package_name) > 0,
            E_PACKAGE_EMPTY_PACKAGE_NAME
        );
        assert!(
            vector::length(&merkle_root) == 32,
            E_PACKAGE_INVALID_MERKLE_ROOT_LENGTH
        );
        assert!(
            vector::length(&manifest_hash) == 32,
            E_PACKAGE_INVALID_MANIFEST_HASH_LENGTH
        );

        let created_at = clock.timestamp_ms();

        let manifest = OCLPManifest {
            manifest_version,
            manifest_integrity_algo,
            manifest_hash,
            manifest_storage_blob_ref,      
            oclp_package_version: OCLP_PACKAGE_VERSION,
        };

        let nft = OCLPPackage {
            id: object::new(ctx),
            domain_id: object::id(domain_registration),
            content_package_name,
            merkle_integrity_algo,
            merkle_root,
            created_at,
            package_storage_blob_ref,
            manifest,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        };

        let package_id = object::id(&nft);

        event::emit(OCLPMintCompletedEvent {
            package_id,
            minter: tx_context::sender(ctx),
            content_package_name: nft.content_package_name,
            merkle_root: nft.merkle_root,
            dependency_merkle_roots,
            minted_at_ms: created_at,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        });

        mint_cap.mint_count = mint_cap.mint_count + 1;
        mint_cap.last_mint_timestamp = created_at;
        
        nft
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Convenience Entry Points
    // ═══════════════════════════════════════════════════════════════════════

    /// Create an OCLP MintCap without going through a domain contract
    /// Use this if a domain has no specific Mint Cap rules.
    /// If a domain has specific Mint Cap rules then it must create
    /// it's own Domain MintCap which wraps the OCLP MintCap
    #[allow(lint(self_transfer))]
    entry fun wallet_create_mint_cap(
        registry: &mut Table<address, bool>,
        policy: &OCLPMintPolicyConfig,
        verified_issuer: &VerifiedIssuer,
        clock: &Clock,
        ctx: &mut tx_context::TxContext,
    ) {
        let mintcap = create_mint_cap(
            registry,
            policy,
            verified_issuer,
            clock,
            ctx,
        );

        transfer::transfer(mintcap, tx_context::sender(ctx));
    }

    /// Mint an OCLP Package NFT directly to the transaction sender
    /// 
    /// Convenience wrapper around `mint()` for direct user minting
    /// without going through a domain contract.
    #[allow(lint(self_transfer))]
    entry fun mint_to_sender(
        domain_reg: &oclp::oclp_domain::OCLPDomainRegistration,
        content_package_name: string::String,
        merkle_integrity_algo: u8,
        merkle_root: vector<u8>,
        package_storage_blob_ref: vector<u8>,
        manifest_version: string::String,
        manifest_integrity_algo: u8,
        manifest_hash: vector<u8>,
        manifest_storage_blob_ref: vector<u8>,
        dependency_merkle_roots: vector<vector<u8>>,
        clock: &Clock,
        mint_cap: &mut OCLPMintCap,
        ctx: &mut tx_context::TxContext
    ) {
        let nft = mint(
            domain_reg,
            content_package_name,
            merkle_integrity_algo,
            merkle_root,
            package_storage_blob_ref,
            manifest_version,
            manifest_integrity_algo,
            manifest_hash,
            manifest_storage_blob_ref,
            dependency_merkle_roots,
            clock,
            mint_cap,
            ctx,
        );

        transfer::public_transfer(nft, tx_context::sender(ctx));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Accessor Functions
    // ═══════════════════════════════════════════════════════════════════════

    /// Get the package ID
    public fun get_id(package: &OCLPPackage): object::ID {
        object::id(package)
    }

    /// Get the package name
    public fun get_package_name(package: &OCLPPackage): string::String {
        package.content_package_name
    }

    /// Get the merkle integrity algorithm code
    public fun get_merkle_integrity_algo(package: &OCLPPackage): u8 {
        package.merkle_integrity_algo
    }

    /// Get the merkle root
    public fun get_merkle_root(package: &OCLPPackage): vector<u8> {
        package.merkle_root
    }

    /// Get the creation timestamp
    public fun get_created_at(package: &OCLPPackage): u64 {
        package.created_at
    }

    /// Get the package storage reference
    public fun get_package_storage_ref(package: &OCLPPackage): vector<u8> {
        package.package_storage_blob_ref
    }

    /// Get the full manifest struct
    public fun get_manifest(package: &OCLPPackage): OCLPManifest {
        package.manifest
    }

    /// Get the manifest version
    public fun get_manifest_version(package: &OCLPPackage): string::String {
        package.manifest.manifest_version
    }

    /// Get the manifest integrity algorithm code
    public fun get_manifest_integrity_algo(package: &OCLPPackage): u8 {
        package.manifest.manifest_integrity_algo
    }

    /// Get the manifest hash
    public fun get_manifest_hash(package: &OCLPPackage): vector<u8> {
        package.manifest.manifest_hash
    }

    /// Get the manifest storage reference
    public fun get_manifest_storage_ref(package: &OCLPPackage): vector<u8> {
        package.manifest.manifest_storage_blob_ref
    }

    /// Get the OCLP package version
    public fun get_oclp_package_version(package: &OCLPPackage): u64 {
        package.oclp_package_version
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Destruction (Composability Primitive)
    // ═══════════════════════════════════════════════════════════════════════

    /// Delete an OCLPPackage, removing it from storage
    /// 
    /// Domain contracts call this when they need to dispose of an
    /// OCLPPackage (e.g., when burning associated content).
    /// 
    /// Only the defining module can deconstruct the struct, so this
    /// function is necessary for composability.
    public fun delete(package: OCLPPackage) {
        let OCLPPackage {
            id,
            domain_id: _,
            content_package_name: _,
            merkle_integrity_algo: _,
            merkle_root: _,
            created_at: _,
            package_storage_blob_ref: _,
            manifest: _,
            oclp_package_version: _,
        } = package;
        
        object::delete(id);
    }

    /// Destroy an OCLPPackage (entry point convenience wrapper)
    /// Direct owners can call this to burn their NFT.
    /// Domain contracts should use `delete()` instead.
    entry fun destroy(package: OCLPPackage) {
        delete(package);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test-only Functions
    // ═══════════════════════════════════════════════════════════════════════

    #[test_only]
    /// Create a test package for unit tests
    public fun create_test_package(
        domain_id: object::ID,
        content_package_name: string::String,
        merkle_root: vector<u8>,
        ctx: &mut tx_context::TxContext
    ): OCLPPackage {
        let manifest = OCLPManifest {
            manifest_version: string::utf8(b"1.4"),
            manifest_integrity_algo: 61,
            manifest_hash: merkle_root,
            manifest_storage_blob_ref: b"test_manifest_ref",
            oclp_package_version: OCLP_PACKAGE_VERSION,
        };

        OCLPPackage {
            id: object::new(ctx),
            domain_id,
            content_package_name,
            merkle_integrity_algo: 61,
            merkle_root,
            created_at: 0,
            package_storage_blob_ref: b"test_package_ref",
            manifest,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        }
    }

    #[test_only]
    /// Create a test mint cap for unit tests
    public fun create_test_mint_cap(
        minter: address,
        cooldown_period: u64,
        total_mint_cap: u64,
        ctx: &mut tx_context::TxContext
    ): OCLPMintCap {
        OCLPMintCap {
            id: object::new(ctx),
            minter,
            cooldown_period,
            last_mint_timestamp: 0,
            verified_issuer_id: object::id_from_address(@0x0),
            total_mint_cap,
            mint_count: 0,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        }
    }

    #[test_only]
    /// Create a test mint cap with specific mint count (for rate limit testing)
    public fun create_test_mint_cap_with_count(
        minter: address,
        cooldown_period: u64,
        last_mint_timestamp: u64,
        total_mint_cap: u64,
        mint_count: u64,
        ctx: &mut tx_context::TxContext
    ): OCLPMintCap {
        OCLPMintCap {
            id: object::new(ctx),
            minter,
            cooldown_period,
            last_mint_timestamp,
            verified_issuer_id: object::id_from_address(@0x0),
            total_mint_cap,
            mint_count,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        }
    }

    #[test_only]
    /// Create a test mint policy config for unit tests
    public fun create_test_mint_policy(
        cooldown_period: u64,
        total_mint_cap: u64,
        ctx: &mut tx_context::TxContext
    ): OCLPMintPolicyConfig {
        OCLPMintPolicyConfig {
            id: object::new(ctx),
            cooldown_period,
            total_mint_cap,
            oclp_package_version: OCLP_PACKAGE_VERSION,
        }
    }

    #[test_only]
    /// Delete test mint cap
    public fun delete_test_mint_cap(mint_cap: OCLPMintCap) {
        let OCLPMintCap {
            id,
            minter: _,
            cooldown_period: _,
            last_mint_timestamp: _,
            verified_issuer_id: _,
            total_mint_cap: _,
            mint_count: _,
            oclp_package_version: _,
        } = mint_cap;
        object::delete(id);
    }

    #[test_only]
    /// Delete test mint policy
    public fun delete_test_mint_policy(policy: OCLPMintPolicyConfig) {
        let OCLPMintPolicyConfig {
            id,
            cooldown_period: _,
            total_mint_cap: _,
            oclp_package_version: _,
        } = policy;
        object::delete(id);
    }

    #[test_only]
    /// Get mint count from mint cap (for testing)
    public fun get_mint_count(mint_cap: &OCLPMintCap): u64 {
        mint_cap.mint_count
    }

    #[test_only]
    /// Get last mint timestamp from mint cap (for testing)
    public fun get_last_mint_timestamp(mint_cap: &OCLPMintCap): u64 {
        mint_cap.last_mint_timestamp
    }
}
