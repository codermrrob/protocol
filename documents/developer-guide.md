# OCLP Developer Guide

## Overview

This guide covers the essential operations for working with the Open Content Licensing Protocol (OCLP) on Sui:

0. Creating a verified issuer (zkLogin wallet verification) - **Required first step**
1. Creating domains (with and without SuiNS verification)
2. Linking SuiNS to existing domains
3. Creating mint capabilities
4. Minting packages with rate limit restrictions

---

## 0. zkLogin Wallet Verification

Before you can create domains or mint capabilities, you must prove ownership of your wallet using zkLogin. This creates a `VerifiedIssuer` object that is required for all OCLP operations.

### 0.1 What is zkLogin?

zkLogin is Sui's zero-knowledge proof system that allows you to prove your wallet was created with a specific OAuth issuer (Google, Facebook, Twitch, etc.) without revealing your OAuth credentials on-chain.

**Key Concepts:**
- **Address Seed**: A unique `u256` value derived from your OAuth sub (subject identifier) and salt
- **Issuer**: The OAuth provider (e.g., "https://accounts.google.com")
- **VerifiedIssuer**: An object proving your wallet's zkLogin credentials

### 0.2 Create Verified Issuer

Creates a `VerifiedIssuer` object that proves your wallet was created using zkLogin with a specific OAuth issuer.

**Public Function:**
```move
public fun create_verified_issuer(
    address_seed: u256,
    issuer: string::String,
    ctx: &mut tx_context::TxContext
)
```

**Parameters:**
- `address_seed` - The `u256` address seed derived from your OAuth sub and salt
- `issuer` - The OAuth issuer URL (e.g., "https://accounts.google.com")
- `ctx` - Transaction context

**Returns/Transfers:**
- Transfers `VerifiedIssuer` object to sender
- The `VerifiedIssuer` contains:
  - `id`: Unique object ID
  - `owner`: Your wallet address
  - `issuer`: The verified OAuth issuer string

**Verification Process:**
The function internally calls `sui::zklogin_verified_issuer::verify_zklogin_issuer()` which:
1. Checks that `sender` matches the zkLogin address derived from `address_seed` and `issuer`
2. Aborts with `EInvalidProof` if verification fails
3. Creates and transfers the `VerifiedIssuer` object on success

**Example CLI:**
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module oclp_zklogin \
  --function create_verified_issuer \
  --args <ADDRESS_SEED_U256> "https://accounts.google.com" \
  --gas-budget 10000000
```

**Example with TypeScript SDK:**
```typescript
import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();

tx.moveCall({
  target: `${packageId}::oclp_zklogin::create_verified_issuer`,
  arguments: [
    tx.pure.u256(addressSeed),  // Your zkLogin address seed
    tx.pure.string('https://accounts.google.com'),  // OAuth issuer
  ],
});

const result = await client.signAndExecuteTransaction({
  transaction: tx,
  signer: keypair,
});
```

### 0.3 How to Obtain Address Seed

The `address_seed` is derived from your OAuth authentication. To obtain it:

**Option 1: Using Sui zkLogin SDK**
```typescript
import { generateNonce, generateRandomness } from '@mysten/zklogin';
import { jwtToAddress } from '@mysten/sui/zklogin';

// 1. Generate randomness and nonce
const ephemeralKeyPair = new Ed25519Keypair();
const randomness = generateRandomness();
const nonce = generateNonce(ephemeralKeyPair.getPublicKey(), maxEpoch, randomness);

// 2. Get JWT from OAuth provider using the nonce
const jwt = await getJWTFromProvider(nonce);

// 3. Decode JWT to get sub and aud
const decodedJWT = decodeJWT(jwt);
const userSalt = await getUserSalt(decodedJWT.sub);

// 4. Calculate address seed
const addressSeed = genAddressSeed(
  BigInt(userSalt),
  'sub',
  decodedJWT.sub,
  decodedJWT.aud
).toString();
```

**Option 2: Using Sui Wallet**
If you're using a wallet that supports zkLogin (e.g., Sui Wallet), the wallet manages the address seed internally. You'll need to:
1. Export or retrieve the address seed from your wallet's zkLogin configuration
2. Use the same issuer that your wallet was created with

### 0.4 Supported OAuth Issuers

Common OAuth issuer strings:
- **Google**: `"https://accounts.google.com"`
- **Facebook**: `"https://www.facebook.com"`
- **Twitch**: `"https://id.twitch.tv/oauth2"`
- **Kakao**: `"https://kauth.kakao.com"`
- **Apple**: `"https://appleid.apple.com"`

**Important:** The issuer string must exactly match the `iss` claim in your OAuth JWT token.

### 0.5 Using Your VerifiedIssuer

Once created, your `VerifiedIssuer` object is required for:
- Creating domains (`create_domain_to_sender`, `create_domain_with_suins_to_sender`)
- Creating mint capabilities (`wallet_create_mint_cap`)

**Ownership:**
- `VerifiedIssuer` is an **owned object** transferred to your wallet
- You must pass it by reference (`&VerifiedIssuer`) to functions that require it
- The object validates that `verified_issuer.owner == tx_sender`

**Reusability:**
- You only need to create one `VerifiedIssuer` per wallet
- The same object can be reused for multiple operations
- Keep track of its object ID for future transactions

### 0.6 Error Handling

**EInvalidProof (from sui::zklogin_verified_issuer)**
- **Cause**: The zkLogin proof verification failed
- **Common reasons**:
  - Incorrect `address_seed` value
  - Wrong `issuer` string (must match OAuth provider exactly)
  - Transaction sender doesn't match the zkLogin-derived address
  - Address seed was generated for a different wallet/keypair

**Debugging Tips:**
1. Verify your `address_seed` calculation matches the zkLogin specification
2. Ensure the `issuer` string exactly matches your OAuth provider's `iss` claim
3. Confirm you're signing the transaction with the correct zkLogin-derived address
4. Check that your OAuth token hasn't expired during the process

### 0.7 Security Considerations

**Best Practices:**
- Never share your `address_seed` or OAuth credentials
- Store your `VerifiedIssuer` object ID securely for reuse
- Use the same OAuth provider consistently for a given wallet
- Verify the issuer string matches your OAuth provider exactly

**Privacy:**
- zkLogin proofs are zero-knowledge - your OAuth credentials are never revealed on-chain
- Only the issuer URL and your wallet address are stored in the `VerifiedIssuer` object
- Your OAuth sub (email, user ID) remains private

---

## 1. Domain Creation

Domains are the foundational primitive in OCLP. Every package mint requires a valid domain registration.

### 1.1 Create Unverified Domain

Creates a basic domain without SuiNS verification (Tier 1).

**Entry Function:**
```move
entry fun create_domain_to_sender(
    registry: &mut OCLPDomainCreationRegistry,
    policy: &OCLPDomainPolicyConfig,
    verified_issuer: &VerifiedIssuer,
    domain_name: String,
    domain_schema: Option<vector<u8>>,
    ctx: &mut tx_context::TxContext
)
```

**Parameters:**
- `registry` - Shared `OCLPDomainCreationRegistry` object (tracks domain counts per wallet)
- `policy` - Shared `OCLPDomainPolicyConfig` object (defines creation limits and mint caps)
- `verified_issuer` - Owned `VerifiedIssuer` object (zkLogin proof of wallet ownership)
- `domain_name` - Human-readable name for your domain (must be non-empty)
- `domain_schema` - Optional Walrus blob ID pointing to domain schema definition
- `ctx` - Transaction context

**Returns/Transfers:**
- Creates a shared `OCLPDomainRegistration` object
- Transfers `OCLPDomainAdminCap` to the sender (proves admin rights over the domain)

**Example CLI:**
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module oclp_domain \
  --function create_domain_to_sender \
  --args <REGISTRY_ID> <POLICY_ID> <VERIFIED_ISSUER_ID> "my-domain" "[]" \
  --gas-budget 10000000
```

**Rate Limits Applied:**
- Unverified domains receive lower mint limits (defined in policy)
- Subject to `max_domains_unverified` limit per wallet

---

### 1.2 Create Verified Domain with SuiNS

Creates a domain with SuiNS verification (Tier 2) - provides higher mint limits.

**Entry Function:**
```move
entry fun create_domain_with_suins_to_sender(
    registry: &mut OCLPDomainCreationRegistry,
    policy: &OCLPDomainPolicyConfig,
    verified_issuer: &VerifiedIssuer,
    suins: &SuiNS,
    sui_ns_name: String,
    domain_name: String,
    domain_schema: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut tx_context::TxContext
)
```

**Parameters:**
- `registry` - Shared `OCLPDomainCreationRegistry` object
- `policy` - Shared `OCLPDomainPolicyConfig` object
- `verified_issuer` - Owned `VerifiedIssuer` object (zkLogin proof)
- `suins` - Shared `SuiNS` object (mainnet: `0x6e0ddefc0ad98889c04bab9639e512c21766c5e6366f89e696956d9be6952871`)
- `sui_ns_name` - Your SuiNS name (e.g., "myname.sui")
- `domain_name` - Human-readable domain name (can differ from SuiNS name)
- `domain_schema` - Optional Walrus blob ID for schema
- `clock` - Shared `Clock` object (`0x6`)
- `ctx` - Transaction context

**Returns/Transfers:**
- Creates a shared `OCLPDomainRegistration` object with SuiNS verification
- Transfers `OCLPDomainAdminCap` to the sender

**Verification Requirements:**
- SuiNS name must exist in the registry
- SuiNS name must not be expired
- SuiNS target address must match transaction sender

**Example CLI:**
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module oclp_domain \
  --function create_domain_with_suins_to_sender \
  --args <REGISTRY_ID> <POLICY_ID> <VERIFIED_ISSUER_ID> \
         0x6e0ddefc0ad98889c04bab9639e512c21766c5e6366f89e696956d9be6952871 \
         "myname.sui" "My Domain" "[]" 0x6 \
  --gas-budget 10000000
```

**Rate Limits Applied:**
- Verified domains receive higher mint limits (defined in policy)
- Subject to `max_domains_verified` limit per wallet

---

## 2. Link SuiNS to Existing Domain

Upgrade an unverified domain to verified status by linking a SuiNS name.

**Entry Function:**
```move
entry fun link_suins_entry(
    registration: &mut OCLPDomainRegistration,
    admin_cap: &OCLPDomainAdminCap,
    policy: &OCLPDomainPolicyConfig,
    suins: &SuiNS,
    sui_ns_name: String,
    clock: &Clock,
    ctx: &mut tx_context::TxContext
)
```

**Parameters:**
- `registration` - Shared `OCLPDomainRegistration` to upgrade
- `admin_cap` - Owned `OCLPDomainAdminCap` proving ownership
- `policy` - Shared `OCLPDomainPolicyConfig` object
- `suins` - Shared `SuiNS` object
- `sui_ns_name` - Your SuiNS name to link
- `clock` - Shared `Clock` object (`0x6`)
- `ctx` - Transaction context

**Effects:**
- Updates domain with SuiNS verification
- Upgrades `daily_mint_limit` to verified tier
- Upgrades `total_mint_cap` to verified tier
- Emits `OCLPDomainSuinsLinkedEvent`

**Example CLI:**
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module oclp_domain \
  --function link_suins_entry \
  --args <DOMAIN_REGISTRATION_ID> <ADMIN_CAP_ID> <POLICY_ID> \
         0x6e0ddefc0ad98889c04bab9639e512c21766c5e6366f89e696956d9be6952871 \
         "myname.sui" 0x6 \
  --gas-budget 10000000
```

---

## 3. Create Mint Capability

Before minting packages, you must create an `OCLPMintCap` - a capability object that proves your right to mint and enforces rate limits.

**Entry Function:**
```move
entry fun wallet_create_mint_cap(
    registry: &mut Table<address, bool>,
    policy: &OCLPMintPolicyConfig,
    verified_issuer: &VerifiedIssuer,
    clock: &Clock,
    ctx: &mut tx_context::TxContext
)
```

**Parameters:**
- `registry` - Shared `OCLPMintCapRegistry` table (tracks which wallets have mint caps)
- `policy` - Shared `OCLPMintPolicyConfig` object (defines cooldown and total cap)
- `verified_issuer` - Owned `VerifiedIssuer` object (zkLogin proof)
- `clock` - Shared `Clock` object (`0x6`)
- `ctx` - Transaction context

**Returns/Transfers:**
- Transfers `OCLPMintCap` to sender (one per wallet)
- Emits `OCLPMintCapCreatedEvent`

**Restrictions:**
- One mint cap per wallet address
- Aborts with `E_WALLET_MINTCAP_EXISTS` if wallet already has a mint cap

**Example CLI:**
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module oclp_package \
  --function wallet_create_mint_cap \
  --args <REGISTRY_ID> <POLICY_ID> <VERIFIED_ISSUER_ID> 0x6 \
  --gas-budget 10000000
```

---

## 4. Mint Package

Mint an OCLP package NFT with content and manifest metadata.

**Entry Function:**
```move
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
    clock: &Clock,
    mint_cap: &mut OCLPMintCap,
    ctx: &mut tx_context::TxContext
)
```

**Parameters:**
- `domain_reg` - Shared `OCLPDomainRegistration` (the domain this package belongs to)
- `content_package_name` - Human-readable package name (must be non-empty)
- `merkle_integrity_algo` - Algorithm code for merkle root (e.g., 61 for Blake2b-256)
- `merkle_root` - 32-byte merkle root hash of package content
- `package_storage_blob_ref` - Storage reference (e.g., Walrus blob ID as bytes)
- `manifest_version` - OCLP manifest format version (e.g., "1.4")
- `manifest_integrity_algo` - Algorithm code for manifest hash (e.g., 61 for Blake2b-256)
- `manifest_hash` - 32-byte hash of manifest document
- `manifest_storage_blob_ref` - Storage reference for manifest (e.g., Walrus blob ID)
- `clock` - Shared `Clock` object (`0x6`)
- `mint_cap` - Owned `OCLPMintCap` (mutable - will be updated with new mint count/timestamp)
- `ctx` - Transaction context

**Returns/Transfers:**
- Transfers `OCLPPackage` NFT to sender
- Updates `mint_cap` with new `mint_count` and `last_mint_timestamp`
- Emits `OCLPPackageMintedEvent`

**Example CLI:**
```bash
sui client call \
  --package <PACKAGE_ID> \
  --module oclp_package \
  --function mint_to_sender \
  --args <DOMAIN_REG_ID> \
         "My Package v1.0" \
         61 \
         "[0x01,0x02,...32 bytes total]" \
         "[0xab,0xcd,...]" \
         "1.4" \
         61 \
         "[0x20,0x1f,...32 bytes total]" \
         "[0xef,0x12,...]" \
         0x6 \
         <MINT_CAP_ID> \
  --gas-budget 10000000
```

---

## 5. Rate Limit Restrictions

**⚠️ IMPORTANT: Rate limits are subject to change based on network conditions and protocol governance.**

### 5.1 Mint Cap Rate Limits

Each `OCLPMintCap` enforces per-wallet rate limits:

**Cooldown Period:**
- Minimum time between mints
- Configured in `OCLPMintPolicyConfig.cooldown_period` (milliseconds)
- Check: `last_mint_timestamp + cooldown_period < current_time`
- **Aborts with `E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS` if violated**

**Total Mint Cap:**
- Maximum total mints per mint cap
- Configured in `OCLPMintPolicyConfig.total_mint_cap`
- Check: `mint_count < total_mint_cap`
- **Aborts with `E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS` if violated**

**Minter Validation:**
- Mint cap is bound to the wallet that created it
- Check: `mint_cap.minter == tx_sender`
- **Aborts with `E_WALLET_INVALID_MINTCAP` if violated**

### 5.2 Domain Rate Limits

Each `OCLPDomainRegistration` enforces domain-level rate limits:

**Daily Mint Limit:**
- Maximum mints per day (epoch-based)
- Unverified: `OCLPDomainPolicyConfig.default_daily_mint_limit_unverified`
- Verified: `OCLPDomainPolicyConfig.default_daily_mint_limit_verified`
- Resets when `current_epoch != last_mint_epoch`
- Check: `mints_today < daily_mint_limit`
- **Aborts with `E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS` if violated**

**Total Domain Mint Cap:**
- Maximum total mints for the domain (lifetime)
- Unverified: `OCLPDomainPolicyConfig.default_total_mint_cap_unverified`
- Verified: `OCLPDomainPolicyConfig.default_total_mint_cap_verified`
- Check: `total_mints < total_mint_cap`
- **Aborts with `E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS` if violated**

### 5.3 Combined Rate Limit Logic

When calling `mint()`, **ALL** of the following must be satisfied:

```move
// Mint cap checks
assert!(mint_cap.minter == sender);
assert!(mint_cap.last_mint_timestamp + mint_cap.cooldown_period < clock.timestamp_ms());
assert!(mint_cap.mint_count < mint_cap.total_mint_cap);

// Domain checks
assert!(domain_reg.mints_today < domain_reg.daily_mint_limit);
assert!(domain_reg.total_mints < domain_reg.total_mint_cap);
```

If any check fails, the transaction aborts.

### 5.4 Typical Rate Limit Values

**Note:** These are example values and may differ on mainnet/testnet.

| Tier | Daily Limit | Total Cap | Cooldown |
|------|-------------|-----------|----------|
| Unverified Domain | 10 | 100 | 60s |
| Verified Domain (SuiNS) | 100 | 10,000 | 60s |
| Mint Cap | N/A | 1,000 | 60s |

### 5.5 Upgrading Rate Limits

To increase your rate limits:

1. **Link SuiNS** - Upgrade from unverified to verified domain using `link_suins_entry()`
2. **Wait for epoch change** - Daily limits reset each epoch
3. **Create new mint cap** - If you've exhausted your mint cap's total limit (requires new wallet or protocol upgrade)

---

## 6. Object Ownership Summary

| Object | Ownership | Purpose |
|--------|-----------|---------|
| `VerifiedIssuer` | Owned | Proves zkLogin wallet verification, required for domain/mint cap creation |
| `OCLPDomainRegistration` | Shared | Public domain record, referenced during minting |
| `OCLPDomainAdminCap` | Owned | Proves admin rights over a domain |
| `OCLPMintCap` | Owned | Proves minting rights, enforces per-wallet rate limits |
| `OCLPPackage` | Owned | The minted package NFT |
| `OCLPDomainCreationRegistry` | Shared | Tracks domain counts per wallet |
| `OCLPDomainPolicyConfig` | Shared | Defines domain creation and mint limits |
| `OCLPMintPolicyConfig` | Shared | Defines mint cap cooldown and total cap |
| `OCLPMintCapRegistry` | Shared | Tracks which wallets have mint caps |

---

## 7. Error Codes Reference

| Code | Constant | Description |
|------|----------|-------------|
| N/A | `EInvalidProof` | zkLogin proof verification failed (from sui::zklogin_verified_issuer) |
| 7 | `E_WALLET_INVALID_MINTCAP` | Mint cap minter doesn't match transaction sender |
| 8 | `E_WALLET_NOT_VERIFIED` | VerifiedIssuer owner doesn't match sender |
| 10 | `E_WALLET_MINTCAP_EXISTS` | Wallet already has a mint cap |
| 103 | `E_DOMAIN_SUINS_NOT_FOUND` | SuiNS name doesn't exist |
| 104 | `E_DOMAIN_SUINS_EXPIRED` | SuiNS name has expired |
| 105 | `E_DOMAIN_SUINS_NOT_POINTING_TO_SENDER` | SuiNS target address doesn't match sender |
| 106 | `E_DOMAIN_EMPTY_DOMAIN_NAME` | Domain name is empty |
| 107 | `E_DOMAIN_ADMIN_CAP_MISMATCH` | Admin cap doesn't match domain or sender |
| 205 | `E_PACKAGE_TOO_MANY_PUBLISH_REQUESTS` | Rate limit exceeded (cooldown, daily, or total cap) |
| 206 | `E_PACKAGE_EMPTY_PACKAGE_NAME` | Package name is empty |
| 207 | `E_PACKAGE_INVALID_MERKLE_ROOT_LENGTH` | Merkle root is not 32 bytes |
| 208 | `E_PACKAGE_INVALID_MANIFEST_HASH_LENGTH` | Manifest hash is not 32 bytes |

---

## 8. Best Practices

1. **Always verify SuiNS** - Get higher rate limits and better trust
2. **Store schemas on Walrus** - Use decentralized storage for domain schemas
3. **Use 32-byte hashes** - Blake2b-256 (algo code 61) is recommended
4. **Monitor rate limits** - Track your mint counts to avoid hitting caps
5. **Plan for cooldowns** - Space out mints to respect cooldown periods
6. **Keep admin caps safe** - They control domain configuration
7. **One mint cap per wallet** - Plan accordingly or use multiple wallets for higher throughput

---

## 9. Additional Resources

- **OCLP Specification**: See protocol documentation for manifest format details
- **Walrus Storage**: https://docs.walrus.site for decentralized storage
- **SuiNS**: https://suins.io for name registration
- **zkLogin**: https://docs.sui.io/concepts/cryptography/zklogin for wallet verification

---

**Last Updated**: January 2026  
**Protocol Version**: 1.0  
**Network**: Sui Mainnet/Testnet
