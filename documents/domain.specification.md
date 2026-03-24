# Domains

A domain is a simple concept that enables:

* Provide deeper semantic meaning to package definition and package content enabling meaningful domain user interaction
* Control access to a domain by enabling private vs public vs public with control vs public and open domains vs commercial
* Define communities of creators
* Enable domain naming, meaningful description, and domain discovery

A domain might include, but not limited to:
* single member completely private content store,
* small groups of friends or family,
* creator communities
* commercial marketplace
* open marketplace

Domains are a core part of OCLP practical usage. Where OCLP provides a base package layer for on-chain package interoperability for lineage and provenance it cannot provide inter-domain package semantics and domain control.

## The Basic Domain Concepts

### Layered Trust

#### Tier 1: Unverified (No SuiNS) - now

- Permissionless creation with verified zkLogin. No zkLogin no domain.
- Hard cap on domains per wallet (< 10?)
- Mint limits enforced (daily + total cap)
- Name collisions possible (who cares at this scale, domain IDs remain unique)
- Discovery is local/informal/word of mouth
#### Tier 2: Verified (SuiNS) - now

- Requires valid SuiNS name
- Mint limits increased
- Uniqueness guaranteed via SuiNS (potential for checking SuiNS VecMap data for domain)
- Discoverable by name across ecosystem
#### Tier 3: Stake - future

* Requires actual capital stake
* Mint limits increased possibly according to stake
* Issues to consider:
	* Who governs stake policy
	* Burn/Slash stake decisions
	* DAO?
#### Tier 4: Activity - future

* Requires activity over time
* Domains need to show good behaviour
* Issues to consider:
	* Domain reputation policing & decisions
	* DAO?
### Register

#### Registration

An on-chain object created for each domain that includes domain minting limits and trust signals.
##### Structs (objects)
```move
// Shared public domain record

public struct OCLPDomainRegistration has key, store {
    id: UID,
    domain_name: String,
    suins_name: Option<String>,
    suins_target_address : Option<address>,
    verified_issuer: ID, // Sui VerifiedIssuer object ID
    domain_schema: Option<vector<u8>> // Walrus blob Id
    
    // Limits (applied differently per tier)
    daily_mint_limit: u64,
    total_mint_cap: u64,
    
    // Tracking
    mints_today: u64,
    last_mint_epoch: u64,
    total_mints: u64,
}


// Owned - proves admin control over a domain. Used for admin actions on
// OCLPOCLPDomainRegistration

    public struct OCLPDomainAdminCap has key, store {
        id: UID,
        domain_id: ID
    }
    
// Public registry of domain counts by wallet
    public struct OCLPDomainCreationRegistry has key {
        id: UID,
        domains_created: Table<address, u64>
    }
```

Optionally contains an off-chain domain schema reference that defines the domains interface schema. Defined as a JSON Schema it describes the discovery entities for the domain (future definition required, similar but simpler than the Swagger/Open API schema).
##### Events
```move

public struct OCLPDomainCreatedEvent has copy, drop {
	domain_id: ID,
	domain_name: String,
	sui_ns: String,
	creator: address,
}


public struct OCLPDomainUpdatedEvent has copy, drop {
	domain_id: ID,
	domain_name: String,
	sui_ns: String,
	updater: address,
}

```

##### Errors
```move
    const ENotOwner: u64 = 1;
    const ETooManyDomains: u64 = 2;
    const ESuinsNotFound: u64 = 3;
    const ESuinsExpired: u64 = 4;
    const ESuinsNotPointingToSender: u64 = 5;
```

Smart contract to create (mint) the domain registration.

##### Methods (domain_registry module)
```move

// Create a verified domain with SuiNS
// 
// Uses the SuiNS core registry to verify:
// 1. The name exists
// 2. The name is not expired
// 3. The name's target address matches the sender
public fun create_domain(
	registry: &mut DomainCreationRegistry,
	policy: &DomainPolicyConfig,
	verified_issuer: &VerifiedIssuer,
	suins: &SuiNS,
	sui_ns_name: String,
	clock: &Clock,
	ctx: &mut TxContext
): DomainAdminCap {
	let sender = tx_context::sender(ctx);
	
	// verify zkLogin ownership
	assert!(verified_issuer.owner == signer::address_of(sender), ENOT_VERIFIED);
	let issuer = sui::zklogin_verified_issuer::issuer(verified_issuer);
	//Optionally check issuer (google, apple, etc) value here
	
	// look up the SuiNS name in the registry
	let domain_obj = domain::new(sui_ns_name);
	let mut optional = suins.registry<Registry>().lookup(domain_obj);
	
	// check that the name exists & is not expired
	assert!(optional.is_some(), ESuinsNotFound);
	
	let name_record = optional.extract();
	assert!(!name_record.has_expired(clock), ESuinsExpired);
	
	// check that the name's target address is the sender
	// check existence to prevent not exist code fail
	assert!(name_record.target_address().is_some(), ESuinsNotPointingToSender);
	// check it is the sender
	assert!(name_record.target_address().extract() == sender, ESuinsNotPointingToSender);
	
	// check domain creation limit
	let max_allowed = domain_admin::domain_policy_create_max(policy, sender);
	let created = get_count(registry, sender);
	assert!(created < max_allowed, ETooManyDomains);
	
	// update creation count
	increment_count(registry, sender);
	
	// create shared registration
	let registration = DomainRegistration {
		id: object::new(ctx),
		domain_name: sui_ns_name,
		sui_ns: sui_ns_name,
		creator: sender,
		total_packages: 0,
	};
	
	let domain_id = object::id(&registration);
	
	// emit event for indexers
	sui::event::emit(DomainCreatedEvent {
		domain_id,
		domain_name: sui_ns_name,
		sui_ns: sui_ns_name,
		creator: sender,
	});
	
	// share the registration
	transfer::share_object(registration);
	
	// 11. Return admin cap to caller
	DomainAdminCap {
		id: object::new(ctx),
		domain_id,
	}
}

    // ============ Helpers ============
    
    fun get_count(registry: &DomainCreationRegistry, wallet: address): u64 {
        if (table::contains(&registry.domains_created, wallet)) {
            *table::borrow(&registry.domains_created, wallet)
        } else {
            0
        }
    }
    
    fun increment_count(registry: &mut DomainCreationRegistry, wallet: address) {
        if (table::contains(&registry.domains_created, wallet)) {
            let count = table::borrow_mut(&mut registry.domains_created, wallet);
            *count = *count + 1;
        } else {
            table::add(&mut registry.domains_created, wallet, 1);
        }
    }
}
```


### Capability - The DomainAdminCap

Issued during domain creation and transferred to sender. Enables updating of domain meta data in the shared `OCLPDomainRegistration` object.
### Schema

Optional JSON Schema to be defined for domain specific entities and properties. It provides a machine readable domain discovery endpoint definition.
## Two Tiers

**Tier 1: Unverified (No SuiNS)**

- Permissionless creation
- Mint limits enforced (daily + total cap)
- Name collisions possible (who cares at this scale)
- Discovery is local/informal

**Tier 2: Verified (SuiNS)**

- Requires valid SuiNS name
- Limits lifted or greatly increased
- Uniqueness guaranteed via SuiNS
- Discoverable by name across ecosystem

