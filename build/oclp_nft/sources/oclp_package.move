module oclp::oclp_package {
    use std::string;
    use sui::clock::Clock;
    use sui::event;

    // ═══════════════════════════════════════════════════════════════════════
    // Error Codes
    // ═══════════════════════════════════════════════════════════════════════
    
    const E_INVALID_MERKLE_ROOT_LENGTH: u64 = 1;
    const E_INVALID_MANIFEST_HASH_LENGTH: u64 = 2;
    const E_EMPTY_PACKAGE_NAME: u64 = 3;

    // ═══════════════════════════════════════════════════════════════════════
    // Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// Embedded manifest metadata
    public struct OCLPManifest has store, drop, copy {
        manifest_version: string::String,
        manifest_integrity_algo: u8,
        manifest_hash: vector<u8>,
        manifest_storage_blob_ref: vector<u8>,
        parent_manifest_id: option::Option<object::ID>,
    }

    /// The OCLP Package NFT - represents cryptographically verified
    /// provenance of a content package.
    /// 
    /// This is the protocol-level primitive. Domain contracts create
    /// wrapper NFTs that reference this by ID for domain-specific
    /// discovery while maintaining protocol-level interoperability.
    public struct OCLPPackage has key, store {
        id: object::UID,
        content_package_name: string::String,
        merkle_integrity_algo: u8,
        merkle_root: vector<u8>,
        created_at: u64,
        package_storage_blob_ref: vector<u8>,
        manifest: OCLPManifest,
    }

    /// Event emitted when an OCLP Package is minted
    public struct MintCompleted has copy, drop {
        package_id: object::ID,
        minter: address,
        content_package_name: string::String,
        merkle_root: vector<u8>,
        minted_at_ms: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Core Minting (Composability Primitive)
    // ═══════════════════════════════════════════════════════════════════════

    /// Mint and return an OCLPPackage
    /// 
    /// This is the primary composability entry point. Domain contracts call
    /// this to receive an OCLPPackage, then create their own wrapper NFT
    /// that references this package by ID.
    ///
    /// The protocol is permissionless and unopinionated. Domain contracts
    /// implement their own access control, pricing, edition limits, etc.
    ///
    /// # Arguments
    /// * `content_package_name` - Human-readable package name
    /// * `merkle_integrity_algo` - Algorithm code for merkle_root verification
    /// * `merkle_root` - Merkle root hash of package content (32 bytes)
    /// * `package_storage_blob_ref` - Storage reference (e.g., Walrus blob ID)
    /// * `manifest_version` - OCLP manifest format version
    /// * `manifest_integrity_algo` - Algorithm code for manifest_hash verification
    /// * `manifest_hash` - Hash of manifest document (32 bytes)
    /// * `manifest_storage_blob_ref` - Storage reference for manifest
    /// * `parent_manifest_id` - Optional parent package for versioning
    /// * `clock` - Sui Clock shared object for timestamps
    /// * `ctx` - Transaction context
    ///
    /// # Returns
    /// The minted OCLPPackage, owned by the calling context
    ///
    /// # Aborts
    /// * `E_EMPTY_PACKAGE_NAME` - If package name is empty
    /// * `E_INVALID_MERKLE_ROOT_LENGTH` - If merkle_root is not 32 bytes
    /// * `E_INVALID_MANIFEST_HASH_LENGTH` - If manifest_hash is not 32 bytes
    public fun mint(
        content_package_name: string::String,
        merkle_integrity_algo: u8,
        merkle_root: vector<u8>,
        package_storage_blob_ref: vector<u8>,
        manifest_version: string::String,
        manifest_integrity_algo: u8,
        manifest_hash: vector<u8>,
        manifest_storage_blob_ref: vector<u8>,
        parent_manifest_id: option::Option<object::ID>,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ): OCLPPackage {
        assert!(
            string::length(&content_package_name) > 0,
            E_EMPTY_PACKAGE_NAME
        );
        assert!(
            vector::length(&merkle_root) == 32,
            E_INVALID_MERKLE_ROOT_LENGTH
        );
        assert!(
            vector::length(&manifest_hash) == 32,
            E_INVALID_MANIFEST_HASH_LENGTH
        );

        let created_at = clock.timestamp_ms();

        let manifest = OCLPManifest {
            manifest_version,
            manifest_integrity_algo,
            manifest_hash,
            manifest_storage_blob_ref,
            parent_manifest_id,
        };

        let nft = OCLPPackage {
            id: object::new(ctx),
            content_package_name,
            merkle_integrity_algo,
            merkle_root,
            created_at,
            package_storage_blob_ref,
            manifest,
        };

        let package_id = object::id(&nft);

        event::emit(MintCompleted {
            package_id,
            minter: tx_context::sender(ctx),
            content_package_name: nft.content_package_name,
            merkle_root: nft.merkle_root,
            minted_at_ms: created_at,
        });

        nft
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Convenience Entry Points
    // ═══════════════════════════════════════════════════════════════════════

    /// Mint an OCLP Package NFT directly to the transaction sender
    /// 
    /// Convenience wrapper around `mint()` for direct user minting
    /// without going through a domain contract.
    #[allow(lint(self_transfer))]
    entry fun mint_to_sender(
        content_package_name: string::String,
        merkle_integrity_algo: u8,
        merkle_root: vector<u8>,
        package_storage_blob_ref: vector<u8>,
        manifest_version: string::String,
        manifest_integrity_algo: u8,
        manifest_hash: vector<u8>,
        manifest_storage_blob_ref: vector<u8>,
        parent_manifest_id: option::Option<object::ID>,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ) {
        let nft = mint(
            content_package_name,
            merkle_integrity_algo,
            merkle_root,
            package_storage_blob_ref,
            manifest_version,
            manifest_integrity_algo,
            manifest_hash,
            manifest_storage_blob_ref,
            parent_manifest_id,
            clock,
            ctx
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

    /// Get the parent manifest ID (if any)
    public fun get_parent_manifest_id(package: &OCLPPackage): option::Option<object::ID> {
        package.manifest.parent_manifest_id
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
            content_package_name: _,
            merkle_integrity_algo: _,
            merkle_root: _,
            created_at: _,
            package_storage_blob_ref: _,
            manifest: _,
        } = package;
        
        object::delete(id);
    }

    /// Destroy an OCLPPackage (entry point convenience wrapper)
    /// 
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
        content_package_name: string::String,
        merkle_root: vector<u8>,
        ctx: &mut tx_context::TxContext
    ): OCLPPackage {
        let manifest = OCLPManifest {
            manifest_version: string::utf8(b"1.4"),
            manifest_integrity_algo: 61,
            manifest_hash: merkle_root,
            manifest_storage_blob_ref: b"test_manifest_ref",
            parent_manifest_id: option::none(),
        };

        OCLPPackage {
            id: object::new(ctx),
            content_package_name,
            merkle_integrity_algo: 61,
            merkle_root,
            created_at: 0,
            package_storage_blob_ref: b"test_package_ref",
            manifest,
        }
    }
}
